
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

void main() {
  runApp(const PageCurlReaderApp());
}

class PageCurlReaderApp extends StatelessWidget {
  const PageCurlReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Page Curl Reader',
      theme: ThemeData.dark(),
      home: const PdfReaderScreen(),
    );
  }
}

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen>
    with SingleTickerProviderStateMixin {
  PdfDocument? _pdfDocument;

  bool _isLoading = true;
  int _totalPages = 0;
  int _currentPage = 1;

  // true = 右開き
  bool _isRightToLeft = true;

  // ページ画像キャッシュ
  final Map<int, ui.Image> _pageCache = {};

  // ページめくり
  late AnimationController _controller;

  double _progress = 0.0;

  bool _dragging = false;
  bool _isNextPage = true;

  // サンプルPDF
  final String _samplePdfUrl =
      'https://raw.githubusercontent.com/mozilla/pdf.js/'
      'ba2edeae/web/compressed.tracemonkey-pldi09.pdf';

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(() {
        if (!mounted) return;

        setState(() {
          _progress = _controller.value;
        });
      });

    _loadPdf();
  }

  @override
  void dispose() {
    _controller.dispose();

    for (final image in _pageCache.values) {
      image.dispose();
    }

    _pdfDocument?.close();

    super.dispose();
  }

  // ============================================================
  // PDF読み込み
  // ============================================================

  Future<void> _loadPdf() async {
    try {
      final response = await http.get(Uri.parse(_samplePdfUrl));

      if (response.statusCode != 200) {
        throw Exception('PDF download failed');
      }

      final dir = await getTemporaryDirectory();

      final file = File(
        '${dir.path}/page_curl_sample.pdf',
      );

      await file.writeAsBytes(response.bodyBytes);

      final document = await PdfDocument.openFile(file.path);

      if (!mounted) return;

      setState(() {
        _pdfDocument = document;
        _totalPages = document.pagesCount;
        _isLoading = false;
      });

      // 最初のページを先読み
      await _loadPageImage(1);

      if (_totalPages >= 2) {
        await _loadPageImage(2);
      }

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('PDF error: $e');

      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });
    }
  }

  // ============================================================
  // PDFページ → ui.Image
  // ============================================================

  Future<ui.Image> _loadPageImage(int pageNumber) async {
    final cached = _pageCache[pageNumber];

    if (cached != null) {
      return cached;
    }

    final document = _pdfDocument;

    if (document == null) {
      throw Exception('PDF not loaded');
    }

    if (pageNumber < 1 || pageNumber > _totalPages) {
      throw Exception('Invalid page');
    }

    final page = await document.getPage(pageNumber);

    try {
      // 解像度を高めにレンダリング
      final image = await page.render(
        width: page.width * 2.0,
        height: page.height * 2.0,
        format: PdfPageImageFormat.png,
      );

      if (image == null) {
        throw Exception('Page rendering failed');
      }

      final codec = await ui.instantiateImageCodec(
        image.bytes,
      );

      final frame = await codec.getNextFrame();

      codec.dispose();

      final result = frame.image;

      _pageCache[pageNumber] = result;

      return result;
    } finally {
      await page.close();
    }
  }

  Future<ui.Image?> _tryLoadPage(int pageNumber) async {
    if (pageNumber < 1 || pageNumber > _totalPages) {
      return null;
    }

    try {
      return await _loadPageImage(pageNumber);
    } catch (e) {
      debugPrint('Page $pageNumber error: $e');
      return null;
    }
  }

  // ============================================================
  // ページ番号
  // ============================================================

  int _underPageNumber() {
    if (_isNextPage) {
      return math.min(
        _currentPage + 1,
        _totalPages,
      );
    }

    return math.max(
      _currentPage - 1,
      1,
    );
  }

  // ============================================================
  // ドラッグ開始
  // ============================================================

  void _onDragStart(
    DragStartDetails details,
    double width,
  ) {
    if (_controller.isAnimating) {
      return;
    }

    final x = details.localPosition.dx;

    bool next;

    if (_isRightToLeft) {
      // 右側から左へ = 次ページ
      next = x > width * 0.35;
    } else {
      // 左側から右へ = 次ページ
      next = x < width * 0.65;
    }

    if (next && _currentPage >= _totalPages) {
      return;
    }

    if (!next && _currentPage <= 1) {
      return;
    }

    _isNextPage = next;

    setState(() {
      _dragging = true;
      _progress = 0.0;
    });
  }

  // ============================================================
  // ドラッグ中
  // ============================================================

  void _onDragUpdate(
    DragUpdateDetails details,
    double width,
  ) {
    if (!_dragging) {
      return;
    }

    final delta = details.primaryDelta ?? 0;

    double amount;

    if (_isRightToLeft) {
      amount = _isNextPage ? -delta : delta;
    } else {
      amount = _isNextPage ? delta : -delta;
    }

    setState(() {
      _progress += amount / width;

      _progress = _progress.clamp(
        0.0,
        1.0,
      );
    });
  }

  // ============================================================
  // 指を離した
  // ============================================================

  Future<void> _onDragEnd(
    DragEndDetails details,
  ) async {
    if (!_dragging) {
      return;
    }

    _dragging = false;

    final velocity = details.primaryVelocity ?? 0;

    bool complete = _progress > 0.22;

    // 強くスワイプした場合
    if (_isRightToLeft) {
      if (_isNextPage && velocity < -450) {
        complete = true;
      }

      if (!_isNextPage && velocity > 450) {
        complete = true;
      }
    } else {
      if (_isNextPage && velocity > 450) {
        complete = true;
      }

      if (!_isNextPage && velocity < -450) {
        complete = true;
      }
    }

    if (complete) {
      await _finishPageTurn();
    } else {
      await _cancelPageTurn();
    }
  }

  // ============================================================
  // ページを最後までめくる
  // ============================================================

  Future<void> _finishPageTurn() async {
    final start = _progress;

    await _controller.animateTo(
      1.0,
      duration: Duration(
        milliseconds:
            math.max(
              120,
              ((1.0 - start) * 360).round(),
            ),
      ),
      curve: Curves.easeOutCubic,
    );

    if (!mounted) return;

    setState(() {
      if (_isNextPage) {
        _currentPage++;
      } else {
        _currentPage--;
      }

      _progress = 0.0;
    });

    _controller.value = 0.0;

    // 次のページを先読み
    unawaited(
      _tryLoadPage(_currentPage + 1),
    );

    unawaited(
      _tryLoadPage(_currentPage - 1),
    );
  }

  // ============================================================
  // ページを元に戻す
  // ============================================================

  Future<void> _cancelPageTurn() async {
    final start = _progress;

    await _controller.animateTo(
      0.0,
      duration: Duration(
        milliseconds:
            math.max(
              100,
              (start * 260).round(),
            ),
      ),
      curve: Curves.easeOutCubic,
    );

    if (!mounted) return;

    setState(() {
      _progress = 0.0;
    });
  }

  // ============================================================
  // 指定ページ
  // ============================================================

  Future<void> _goToPage(int page) async {
    if (page < 1 ||
        page > _totalPages ||
        page == _currentPage) {
      return;
    }

    setState(() {
      _currentPage = page;
      _progress = 0.0;
    });

    await _tryLoadPage(page);
    await _tryLoadPage(page + 1);
    await _tryLoadPage(page - 1);

    if (mounted) {
      setState(() {});
    }
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final screenWidth =
        MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor:
          const Color(0xFF302A25),

      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : _pdfDocument == null
              ? const Center(
                  child: Text(
                    'PDFの読み込みに失敗しました',
                  ),
                )
              : SafeArea(
                  child: Column(
                    children: [
                      _buildTopBar(),

                      Expanded(
                        child: GestureDetector(
                          behavior:
                              HitTestBehavior.opaque,

                          onHorizontalDragStart:
                              (details) =>
                                  _onDragStart(
                            details,
                            screenWidth,
                          ),

                          onHorizontalDragUpdate:
                              (details) =>
                                  _onDragUpdate(
                            details,
                            screenWidth,
                          ),

                          onHorizontalDragEnd:
                              _onDragEnd,

                          child:
                              _buildReaderArea(),
                        ),
                      ),

                      _buildBottomBar(),
                    ],
                  ),
                ),
    );
  }

  // ============================================================
  // 上部バー
  // ============================================================

  Widget _buildTopBar() {
    return Container(
      height: 64,
      color: const Color(0xFF2A231E),
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
      ),
      child: Row(
        mainAxisAlignment:
            MainAxisAlignment.spaceBetween,
        children: [
          DropdownButton<int>(
            value: _currentPage,
            dropdownColor:
                const Color(0xFF332C27),
            underline: const SizedBox(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
            ),
            items: List.generate(
              _totalPages,
              (index) {
                final page = index + 1;

                return DropdownMenuItem<int>(
                  value: page,
                  child: Text(
                    '$page / $_totalPages ページ',
                  ),
                );
              },
            ),
            onChanged: (value) {
              if (value != null) {
                _goToPage(value);
              }
            },
          ),

          TextButton.icon(
            onPressed: () {
              setState(() {
                _isRightToLeft =
                    !_isRightToLeft;
              });
            },

            icon: Icon(
              _isRightToLeft
                  ? Icons.arrow_back
                  : Icons.arrow_forward,
              color: Colors.white,
            ),

            label: Text(
              _isRightToLeft
                  ? '← 右開き'
                  : '左開き →',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 読書エリア
  // ============================================================

  Widget _buildReaderArea() {
    final underPage =
        _underPageNumber();

    final topPage =
        _currentPage;

    return FutureBuilder<List<ui.Image?>>(
      future: Future.wait([
        _tryLoadPage(underPage),
        _tryLoadPage(topPage),
      ]),
      builder: (
        context,
        snapshot,
      ) {
        if (!snapshot.hasData) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        final images =
            snapshot.data!;

        final underImage =
            images[0];

        final topImage =
            images[1];

        if (topImage == null) {
          return const Center(
            child: Text(
              'ページを表示できません',
            ),
          );
        }

        return CustomPaint(
          painter: PageCurlPainter(
            currentPage: topImage,
            underPage: underImage,
            progress: _progress,
            isNextPage: _isNextPage,
            isRightToLeft:
                _isRightToLeft,
          ),
          size: Size.infinite,
        );
      },
    );
  }

  // ============================================================
  // 下部スライダー
  // ============================================================

  Widget _buildBottomBar() {
    return Container(
      color: const Color(0xFF2A231E),
      padding:
          const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 8,
      ),
      child: Slider(
        value: _currentPage.toDouble(),
        min: 1,
        max:
            math.max(
              1,
              _totalPages.toDouble(),
            ),
        divisions:
            _totalPages > 1
                ? _totalPages - 1
                : 1,
        onChanged: (value) {
          _goToPage(
            value.round(),
          );
        },
      ),
    );
  }
}

// ============================================================================
// ページカール・ペインター
// ============================================================================

class PageCurlPainter
    extends CustomPainter {
  final ui.Image currentPage;
  final ui.Image? underPage;

  final double progress;

  final bool isNextPage;
  final bool isRightToLeft;

  static const int columns = 36;
  static const int rows = 10;

  PageCurlPainter({
    required this.currentPage,
    required this.underPage,
    required this.progress,
    required this.isNextPage,
    required this.isRightToLeft,
  });

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    // ----------------------------------------------------------
    // 背景
    // ----------------------------------------------------------

    final bgPaint = Paint()
      ..color =
          const Color(0xFFD0B59D);

    canvas.drawRect(
      Offset.zero &
          size,
      bgPaint,
    );

    // ----------------------------------------------------------
    // 下のページ
    // ----------------------------------------------------------

    if (underPage != null) {
      _drawPage(
        canvas,
        underPage!,
        size,
      );
    }

    // ----------------------------------------------------------
    // めくり開始前
    // ----------------------------------------------------------

    if (progress <= 0.0001) {
      _drawPage(
        canvas,
        currentPage,
        size,
      );

      return;
    }

    // ----------------------------------------------------------
    // 現在ページをカール
    // ----------------------------------------------------------

    _drawCurlPage(
      canvas,
      currentPage,
      size,
    );
  }

  // ========================================================================
  // 通常ページ
  // ========================================================================

  void _drawPage(
    Canvas canvas,
    ui.Image image,
    Size size,
  ) {
    final dst =
        _fitRect(
      image,
      size,
    );

    final paint = Paint()
      ..filterQuality =
          FilterQuality.medium;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      dst,
      paint,
    );
  }

  // ========================================================================
  // ページをカールさせる
  // ========================================================================

  void _drawCurlPage(
    Canvas canvas,
    ui.Image image,
    Size size,
  ) {
    final pageRect =
        _fitRect(
      image,
      size,
    );

    canvas.save();

    canvas.clipRect(
      Offset.zero & size,
    );

    // ページ座標
    final left =
        pageRect.left;

    final top =
        pageRect.top;

    final width =
        pageRect.width;

    final height =
        pageRect.height;

    // ----------------------------------------------------------
    // めくり方向
    // ----------------------------------------------------------

    final nextDirection =
        isRightToLeft
            ? isNextPage
            : !isNextPage;

    // true:
    // ページの右端から左へ
    //
    // false:
    // ページの左端から右へ

    // ----------------------------------------------------------
    // 平らな部分の終点
    // ----------------------------------------------------------

    final flatWidth =
        width * (1.0 - progress);

    final foldX = nextDirection
        ? left + flatWidth
        : left + width - flatWidth;

    // ----------------------------------------------------------
    // メッシュ
    // ----------------------------------------------------------

    final positions =
        <Offset>[];

    final textures =
        <Offset>[];

    final colors =
        <Color>[];

    final indices =
        <int>[];

    final sourceWidth =
        image.width.toDouble();

    final sourceHeight =
        image.height.toDouble();

    // カール部分の幅
    final curlWidth =
        width * progress;

    final safeCurlWidth =
        math.max(
          1.0,
          curlWidth,
        );

    // 最大カール角
    //
    // 0 → 平ら
    // 1 → 約180度
    //
    final maxAngle =
        math.pi *
        progress;

    // 円筒の半径
    final radius =
        safeCurlWidth /
            math.max(
              2.0,
              maxAngle,
            );

    // ----------------------------------------------------------
    // メッシュ生成
    // ----------------------------------------------------------

    for (int y = 0;
        y <= rows;
        y++) {
      final v =
          y / rows;

      final py =
          top + height * v;

      for (int x = 0;
          x <= columns;
          x++) {
        final u =
            x / columns;

        final sourceX =
            sourceWidth * u;

        final sourceY =
            sourceHeight * v;

        double destX;
        double destY;

        double shade;

        // ======================================================
        // 次ページへ
        // ======================================================

        if (nextDirection) {
          final curlStart =
              1.0 - progress;

          if (u <= curlStart) {
            // -------------------------------
            // 平らなページ
            // -------------------------------

            final flatU =
                curlStart <= 0
                    ? 0
                    : u / curlStart;

            destX =
                left +
                flatWidth *
                    flatU;

            destY =
                py;

            shade = 1.0;
          } else {
            // -------------------------------
            // カール部分
            // -------------------------------

            final t =
                (u - curlStart) /
                    math.max(
                      0.0001,
                      progress,
                    );

            final angle =
                t * maxAngle;

            // 円筒状に曲げる
            destX =
                foldX -
                radius *
                    (1.0 -
                        math.cos(
                          angle,
                        ));

            // 少しだけ紙が浮く
            final lift =
                math.sin(angle) *
                    math.sin(
                      math.pi * v,
                    ) *
                    math.min(
                      18.0,
                      height * 0.025,
                    );

            destY =
                py + lift;

            // 曲面の明暗
            shade =
                0.70 +
                    0.30 *
                        math.cos(
                          angle,
                        );
          }
        }

        // ======================================================
        // 前ページへ
        // ======================================================

        else {
          final curlStart =
              progress;

          if (u >= curlStart) {
            // -------------------------------
            // 平らなページ
            // -------------------------------

            final flatU =
                (u - curlStart) /
                    math.max(
                      0.0001,
                      1.0 -
                          curlStart,
                    );

            destX =
                left +
                width *
                    progress +
                width *
                    (1.0 -
                        progress) *
                    flatU;

            destY =
                py;

            shade = 1.0;
          } else {
            // -------------------------------
            // 左からカール
            // -------------------------------

            final t =
                u /
                    math.max(
                      0.0001,
                      progress,
                    );

            final angle =
                t * maxAngle;

            final fold =
                left +
                    width -
                    flatWidth;

            destX =
                fold +
                    radius *
                        (1.0 -
                            math.cos(
                              angle,
                            ));

            final lift =
                math.sin(angle) *
                    math.sin(
                      math.pi * v,
                    ) *
                    math.min(
                      18.0,
                      height * 0.025,
                    );

            destY =
                py + lift;

            shade =
                0.70 +
                    0.30 *
                        math.cos(
                          angle,
                        );
          }
        }

        // ------------------------------------------------------
        // 少しだけ立体感
        // ------------------------------------------------------

        final normalizedShade =
            shade.clamp(
              0.35,
              1.0,
            );

        positions.add(
          Offset(
            destX,
            destY,
          ),
        );

        textures.add(
          Offset(
            sourceX,
            sourceY,
          ),
        );

        colors.add(
          Color.fromRGBO(
            255,
            255,
            255,
            normalizedShade,
          ),
        );
      }
    }

    // ----------------------------------------------------------
    // 三角形
    // ----------------------------------------------------------

    final stride =
        columns + 1;

    for (int y = 0;
        y < rows;
        y++) {
      for (int x = 0;
          x < columns;
          x++) {
        final a =
            y * stride + x;

        final b =
            a + 1;

        final c =
            a + stride;

        final d =
            c + 1;

        indices.add(a);
        indices.add(c);
        indices.add(b);

        indices.add(b);
        indices.add(c);
        indices.add(d);
      }
    }

    // ----------------------------------------------------------
    // テクスチャ付きメッシュ
    // ----------------------------------------------------------

    final vertices =
        ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates:
          textures,
      colors: colors,
      indices: indices,
    );

    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Float64List.fromList([
          1, 0, 0, 0,
          0, 1, 0, 0,
          0, 0, 1, 0,
          0, 0, 0, 1,
        ]),
        filterQuality:
            FilterQuality.medium,
      );

    canvas.drawVertices(
      vertices,
      BlendMode.modulate,
      paint,
    );

    vertices.dispose();

    canvas.restore();

    // ----------------------------------------------------------
    // カールの影
    // ----------------------------------------------------------

    _drawCurlShadow(
      canvas,
      size,
      pageRect,
    );
  }

  // ========================================================================
  // カールの影
  // ========================================================================

  void _drawCurlShadow(
    Canvas canvas,
    Size size,
    Rect pageRect,
  ) {
    if (progress <= 0) {
      return;
    }

    final nextDirection =
        isRightToLeft
            ? isNextPage
            : !isNextPage;

    final shadowWidth =
        math.max(
          10.0,
          pageRect.width *
              0.035 *
              progress,
        );

    final foldX = nextDirection
        ? pageRect.left +
            pageRect.width *
                (1.0 - progress)
        : pageRect.left +
            pageRect.width *
                progress;

    final rect =
        nextDirection
            ? Rect.fromLTWH(
                foldX -
                    shadowWidth,
                pageRect.top,
                shadowWidth,
                pageRect.height,
              )
            : Rect.fromLTWH(
                foldX,
                pageRect.top,
                shadowWidth,
                pageRect.height,
              );

    final gradient =
        nextDirection
            ? LinearGradient(
                begin:
                    Alignment.centerLeft,
                end:
                    Alignment.centerRight,
                colors: [
                  Colors.black.withOpacity(
                    0.28 *
                        progress,
                  ),
                  Colors.transparent,
                ],
              )
            : LinearGradient(
                begin:
                    Alignment.centerRight,
                end:
                    Alignment.centerLeft,
                colors: [
                  Colors.black.withOpacity(
                    0.28 *
                        progress,
                  ),
                  Colors.transparent,
                ],
              );

    final paint =
        Paint()
          ..shader =
              gradient.createShader(
            rect,
          );

    canvas.drawRect(
      rect,
      paint,
    );
  }

  // ========================================================================
  // 画像を画面内に収める
  // ========================================================================

  Rect _fitRect(
    ui.Image image,
    Size size,
  ) {
    final imageRatio =
        image.width /
            image.height;

    final screenRatio =
        size.width /
            size.height;

    double width;
    double height;

    if (imageRatio > screenRatio) {
      width = size.width;
      height =
          width / imageRatio;
    } else {
      height = size.height;
      width =
          height * imageRatio;
    }

    final left =
        (size.width - width) / 2;

    final top =
        (size.height - height) / 2;

    return Rect.fromLTWH(
      left,
      top,
      width,
      height,
    );
  }

  @override
  bool shouldRepaint(
    covariant PageCurlPainter oldDelegate,
  ) {
    return oldDelegate.currentPage !=
            currentPage ||
        oldDelegate.underPage !=
            underPage ||
        oldDelegate.progress !=
            progress ||
        oldDelegate.isNextPage !=
            isNextPage ||
        oldDelegate.isRightToLeft !=
            isRightToLeft;
  }
}
