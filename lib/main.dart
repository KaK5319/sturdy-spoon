import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Real 3D Page Curl Reader',
      debugShowCheckedModeBanner: false,
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
  bool _isRightToLeft = true; // デフォルト右開き

  // ページ画像のキャッシュ (ui.Image)
  final Map<int, ui.Image> _pageCache = {};

  late AnimationController _animController;
  double _dragProgress = 0.0; // 0.0 ~ 1.0
  bool _isDragging = false;
  bool _isNextPage = true;

  final String _samplePdfUrl =
      'https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/web/compressed.tracemonkey-pldi09.pdf';

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..addListener(() {
        setState(() {
          _dragProgress = _animController.value;
        });
      });

    _loadPdf();
  }

  @override
  void dispose() {
    _animController.dispose();
    for (final img in _pageCache.values) {
      img.dispose();
    }
    _pdfDocument?.close();
    super.dispose();
  }

  // ============================================================
  // PDF読み込み & ui.Image 化
  // ============================================================

  Future<void> _loadPdf() async {
    try {
      final response = await http.get(Uri.parse(_samplePdfUrl));
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sample.pdf');
      await file.writeAsBytes(response.bodyBytes);

      final doc = await PdfDocument.openFile(file.path);
      if (!mounted) return;

      setState(() {
        _pdfDocument = doc;
        _totalPages = doc.pagesCount;
        _isLoading = false;
      });

      // 前後のページをあらかじめキャッシュ
      await _getPageImage(1);
      if (_totalPages >= 2) await _getPageImage(2);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error loading PDF: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<ui.Image?> _getPageImage(int pageNumber) async {
    if (pageNumber < 1 || pageNumber > _totalPages) return null;
    if (_pageCache.containsKey(pageNumber)) {
      return _pageCache[pageNumber]!;
    }

    if (_pdfDocument == null) return null;

    final page = await _pdfDocument!.getPage(pageNumber);
    try {
      final pageImage = await page.render(
        width: page.width * 2.0,
        height: page.height * 2.0,
        format: PdfPageImageFormat.png,
      );
      if (pageImage == null) return null;

      final codec = await ui.instantiateImageCodec(pageImage.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();

      final result = frame.image;
      _pageCache[pageNumber] = result;
      return result;
    } finally {
      await page.close();
    }
  }

  // ============================================================
  // ジェスチャー・めくり処理
  // ============================================================

  void _onHorizontalDragStart(DragStartDetails details, double screenWidth) {
    if (_animController.isAnimating) return;

    final dx = details.localPosition.dx;
    bool next;

    if (_isRightToLeft) {
      next = dx > screenWidth * 0.35;
    } else {
      next = dx < screenWidth * 0.65;
    }

    if (next && _currentPage >= _totalPages) return;
    if (!next && _currentPage <= 1) return;

    _isNextPage = next;
    setState(() {
      _isDragging = true;
      _dragProgress = 0.0;
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, double screenWidth) {
    if (!_isDragging) return;

    final delta = details.primaryDelta ?? 0;
    double factor;

    if (_isRightToLeft) {
      factor = _isNextPage ? -delta : delta;
    } else {
      factor = _isNextPage ? delta : -delta;
    }

    setState(() {
      _dragProgress += factor / screenWidth;
      _dragProgress = _dragProgress.clamp(0.0, 1.0);
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    _isDragging = false;

    final velocity = details.primaryVelocity ?? 0;
    bool complete = _dragProgress > 0.2;

    // フリック判定
    if (_isRightToLeft) {
      if (_isNextPage && velocity < -400) complete = true;
      if (!_isNextPage && velocity > 400) complete = true;
    } else {
      if (_isNextPage && velocity > 400) complete = true;
      if (!_isNextPage && velocity < -400) complete = true;
    }

    if (complete) {
      final start = _dragProgress;
      _animController
          .animateTo(1.0,
              duration: Duration(
                  milliseconds: math.max(100, ((1.0 - start) * 300).round())),
              curve: Curves.easeOutCubic)
          .then((_) {
        if (!mounted) return;
        setState(() {
          if (_isNextPage) {
            _currentPage++;
          } else {
            _currentPage--;
          }
          _dragProgress = 0.0;
        });
        _animController.value = 0.0;

        // 隣接ページのプリロード
        _getPageImage(_currentPage + 1);
        _getPageImage(_currentPage - 1);
      });
    } else {
      final start = _dragProgress;
      _animController
          .animateTo(0.0,
              duration: Duration(
                  milliseconds: math.max(80, (start * 200).round())),
              curve: Curves.easeOutCubic)
          .then((_) {
        if (!mounted) return;
        setState(() {
          _dragProgress = 0.0;
        });
      });
    }
  }

  void _goToPage(int page) {
    if (page < 1 || page > _totalPages || page == _currentPage) return;
    setState(() {
      _currentPage = page;
      _dragProgress = 0.0;
    });
    _getPageImage(page);
    _getPageImage(page + 1);
    _getPageImage(page - 1);
  }

  int _getTopPageNumber() => _currentPage;
  int _getUnderPageNumber() {
    if (_isNextPage) {
      return math.min(_currentPage + 1, _totalPages);
    } else {
      return math.max(_currentPage - 1, 1);
    }
  }

  // ============================================================
  // メイン画面描画
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: const Color(0xFF231F1C),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _pdfDocument == null
              ? const Center(child: Text('PDFの読み込みに失敗しました'))
              : SafeArea(
                  child: Column(
                    children: [
                      _buildTopBar(),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (details) =>
                              _onHorizontalDragStart(details, screenWidth),
                          onHorizontalDragUpdate: (details) =>
                              _onHorizontalDragUpdate(details, screenWidth),
                          onHorizontalDragEnd: _onHorizontalDragEnd,
                          child: _buildCurlReaderArea(),
                        ),
                      ),
                      _buildBottomBar(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      color: const Color(0xFF191614),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          DropdownButton<int>(
            value: _currentPage,
            dropdownColor: const Color(0xFF2D2723),
            style: const TextStyle(color: Colors.white, fontSize: 16),
            items: List.generate(_totalPages, (index) {
              return DropdownMenuItem(
                value: index + 1,
                child: Text('${index + 1} / $_totalPages ページ'),
              );
            }),
            onChanged: (value) {
              if (value != null) _goToPage(value);
            },
          ),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _isRightToLeft = !_isRightToLeft;
              });
            },
            icon: Icon(
              _isRightToLeft ? Icons.arrow_back : Icons.arrow_forward,
              color: Colors.white,
            ),
            label: Text(
              _isRightToLeft ? '← 右開き' : '左開き →',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurlReaderArea() {
    final topPage = _getTopPageNumber();
    final underPage = _getUnderPageNumber();

    return FutureBuilder<List<ui.Image?>>(
      future: Future.wait([
        _getPageImage(underPage),
        _getPageImage(topPage),
      ]),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final underImage = snapshot.data![0];
        final topImage = snapshot.data![1];

        if (topImage == null) {
          return const Center(child: Text('ページを表示できません'));
        }

        return CustomPaint(
          painter: RealPageCurlPainter(
            currentPage: topImage,
            underPage: underImage,
            progress: _dragProgress,
            isNextPage: _isNextPage,
            isRightToLeft: _isRightToLeft,
          ),
          size: Size.infinite,
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      color: const Color(0xFF191614),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Slider(
        value: _currentPage.toDouble(),
        min: 1,
        max: math.max(1, _totalPages.toDouble()),
        divisions: _totalPages > 1 ? _totalPages - 1 : 1,
        onChanged: (value) => _goToPage(value.round()),
      ),
    );
  }
}

// ============================================================================
// リアル3D ページカール・ペインター（曲面メッシュ＆立体影）
// ============================================================================

class RealPageCurlPainter extends CustomPainter {
  final ui.Image currentPage;
  final ui.Image? underPage;
  final double progress;
  final bool isNextPage;
  final bool isRightToLeft;

  // メッシュの分割数（数値が高いほど滑らかな曲面になる）
  static const int columns = 40;
  static const int rows = 12;

  RealPageCurlPainter({
    required this.currentPage,
    required this.underPage,
    required this.progress,
    required this.isNextPage,
    required this.isRightToLeft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 背景色（テーブル・本底面）
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1E1A17),
    );

    // 2. 下層（めくられた後に見えてくる）ページを描画
    if (underPage != null) {
      _drawFlatPage(canvas, underPage!, size);
    }

    // めくり未発生時はそのまま表面を描画
    if (progress <= 0.0001) {
      _drawFlatPage(canvas, currentPage, size);
      return;
    }

    // 3. 上層（めくられる）ページの曲面カ mult 描画
    _drawCurlPage(canvas, currentPage, size);
  }

  void _drawFlatPage(Canvas canvas, ui.Image image, Size size) {
    final dst = _fitRect(image, size);
    final paint = Paint()..filterQuality = FilterQuality.medium;

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      paint,
    );
  }

  Rect _fitRect(ui.Image image, Size size) {
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final imgRatio = imgW / imgH;
    final screenRatio = size.width / size.height;

    double dstW, dstH;
    if (imgRatio > screenRatio) {
      dstW = size.width;
      dstH = size.width / imgRatio;
    } else {
      dstH = size.height;
      dstW = size.height * imgRatio;
    }

    final dx = (size.width - dstW) / 2;
    final dy = (size.height - dstH) / 2;
    return Rect.fromLTWH(dx, dy, dstW, dstH);
  }

  void _drawCurlPage(Canvas canvas, ui.Image image, Size size) {
    final pageRect = _fitRect(image, size);

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final left = pageRect.left;
    final top = pageRect.top;
    final width = pageRect.width;
    final height = pageRect.height;

    final isRTL = (_isRightToLeft && isNextPage) || (!_isRightToLeft && !isNextPage);

    final curlWidth = width * progress;
    final safeCurlWidth = math.max(1.0, curlWidth);
    final maxAngle = math.pi * progress;
    final radius = safeCurlWidth / math.max(1.5, maxAngle);

    // --- A. 下層ページへ落ちる動的な影 (Drop Shadow) ---
    _drawDropShadow(canvas, pageRect, isRTL, curlWidth, radius);

    // --- B. 3D曲面メッシュの頂点・テクスチャ・陰影計算 ---
    final positions = <Offset>[];
    final textures = <Offset>[];
    final colors = <Color>[];
    final indices = <int>[];

    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    for (int y = 0; y <= rows; y++) {
      final v = y / rows;
      final py = top + height * v;

      for (int x = 0; x <= columns; x++) {
        final u = x / columns;
        final sourceX = imgW * u;
        final sourceY = imgH * v;

        double destX;
        double destY = py;
        double shade;

        if (isRTL) {
          final curlStart = 1.0 - progress;
          if (u <= curlStart) {
            destX = left + width * u;
            shade = 1.0;
          } else {
            final localU = (u - curlStart) / math.max(0.0001, progress);
            final angle = localU * maxAngle;
            final foldX = left + width * curlStart;

            destX = foldX + math.sin(angle) * radius;
            // 湾曲具合と巻き込み深さに応じた動的グラデーション
            shade = math.max(0.25, math.cos(angle * 0.55));
          }
        } else {
          final curlStart = progress;
          if (u >= curlStart) {
            destX = left + width * u;
            shade = 1.0;
          } else {
            final localU = (curlStart - u) / math.max(0.0001, progress);
            final angle = localU * maxAngle;
            final foldX = left + width * curlStart;

            destX = foldX - math.sin(angle) * radius;
            shade = math.max(0.25, math.cos(angle * 0.55));
          }
        }

        positions.add(Offset(destX, destY));
        textures.add(Offset(sourceX, sourceY));

        final c = (255 * shade).round().clamp(0, 255);
        colors.add(Color.fromARGB(255, c, c, c));
      }
    }

    // 三角形メッシュインデックスの生成
    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < columns; x++) {
        final i1 = y * (columns + 1) + x;
        final i2 = i1 + 1;
        final i3 = (y + 1) * (columns + 1) + x;
        final i4 = i3 + 1;

        indices.addAll([i1, i2, i3]);
        indices.addAll([i2, i4, i3]);
      }
    }

    final paint = Paint()
      ..shader = ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        Float64List.fromList([
          1, 0, 0, 0,
          0, 1, 0, 0,
          0, 0, 1, 0,
          0, 0, 0, 1,
        ]),
      );

    final vertices = ui.Vertices(
      VertexMode.triangles,
      positions,
      textureCoordinates: textures,
      colors: colors,
      indices: indices,
    );

    canvas.drawVertices(vertices, BlendMode.modulate, paint);
    canvas.restore();
  }

  // 下層ページ上に投影されるリアルな落ち影
  void _drawDropShadow(Canvas canvas, Rect pageRect, bool isRTL, double curlWidth, double radius) {
    final shadowWidth = math.min(curlWidth * 0.6, radius * 2.5);
    if (shadowWidth <= 1.0) return;

    final double shadowLeft;
    if (isRTL) {
      shadowLeft = pageRect.right - curlWidth - shadowWidth;
    } else {
      shadowLeft = pageRect.left + curlWidth;
    }

    final shadowRect = Rect.fromLTWH(
      shadowLeft,
      pageRect.top,
      shadowWidth,
      pageRect.height,
    );

    final shadowPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(shadowRect.left, 0),
        Offset(shadowRect.right, 0),
        isRTL
            ? [Colors.transparent, Colors.black.withOpacity(0.45 * progress)]
            : [Colors.black.withOpacity(0.45 * progress), Colors.transparent],
      );

    canvas.drawRect(shadowRect, shadowPaint);
  }

  @override
  bool shouldRepaint(covariant RealPageCurlPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.currentPage != currentPage ||
        oldDelegate.underPage != underPage ||
        oldDelegate.isNextPage != isNextPage ||
        oldDelegate.isRightToLeft != isRightToLeft;
  }
}
