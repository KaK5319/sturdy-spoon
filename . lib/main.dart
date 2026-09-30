import 'dart:io';
import 'dart:math' as math;
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
      title: 'PDF Reader',
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

class _PdfReaderScreenState extends State<PdfReaderScreen> with SingleTickerProviderStateMixin {
  PdfDocument? _pdfDocument;
  bool _isLoading = true;
  int _totalPages = 0;
  int _currentPage = 1;
  bool _isRightToLeft = true; // デフォルト右開き

  final Map<int, ImageProvider> _pageCache = {};

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
      duration: const Duration(milliseconds: 200),
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
    super.dispose();
  }

  Future<void> _loadPdf() async {
    try {
      final response = await http.get(Uri.parse(_samplePdfUrl));
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sample.pdf');
      await file.writeAsBytes(response.bodyBytes);

      final doc = await PdfDocument.openFile(file.path);
      setState(() {
        _pdfDocument = doc;
        _totalPages = doc.pagesCount;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading PDF: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<ImageProvider> _getPageImage(int pageNumber) async {
    if (pageNumber < 1 || pageNumber > _totalPages) {
      return const MemoryImage(transparentPixel);
    }
    if (_pageCache.containsKey(pageNumber)) {
      return _pageCache[pageNumber]!;
    }

    if (_pdfDocument == null) throw Exception("Document not loaded");

    final page = await _pdfDocument!.getPage(pageNumber);
    final pageImage = await page.render(
      width: page.width * 2,
      height: page.height * 2,
      format: PdfPageImageFormat.jpeg,
    );
    await page.close();

    final provider = MemoryImage(pageImage!.bytes);
    _pageCache[pageNumber] = provider;
    return provider;
  }

  static const transparentPixel = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82
  ];

  void _onHorizontalDragStart(DragStartDetails details, double screenWidth) {
    if (_animController.isAnimating) return;

    final dx = details.localPosition.dx;
    
    if (_isRightToLeft) {
      if (dx > screenWidth * 0.3) {
        if (_currentPage >= _totalPages) return;
        _isNextPage = true;
      } else {
        if (_currentPage <= 1) return;
        _isNextPage = false;
      }
    } else {
      if (dx < screenWidth * 0.7) {
        if (_currentPage >= _totalPages) return;
        _isNextPage = true;
      } else {
        if (_currentPage <= 1) return;
        _isNextPage = false;
      }
    }

    setState(() {
      _isDragging = true;
      _dragProgress = 0.0;
    });
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, double screenWidth) {
    if (!_isDragging) return;

    double delta = details.primaryDelta ?? 0;
    double factor = 0;
    
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

    if (_dragProgress > 0.15) {
      _animController.forward(from: _dragProgress).then((_) {
        setState(() {
          if (_isNextPage) {
            _currentPage++;
          } else {
            _currentPage--;
          }
          _dragProgress = 0.0;
        });
      });
    } else {
      _animController.reverse(from: _dragProgress).then((_) {
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
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _pdfDocument == null
              ? const Center(child: Text('PDFの読み込みに失敗しました'))
              : SafeArea(
                  child: Column(
                    children: [
                      // 上部バー
                      Container(
                        color: Colors.black87,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            DropdownButton<int>(
                              value: _currentPage,
                              dropdownColor: Colors.grey[900],
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
                      ),

                      // 中央めくりエリア
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (details) => _onHorizontalDragStart(details, screenWidth),
                          onHorizontalDragUpdate: (details) => _onHorizontalDragUpdate(details, screenWidth),
                          onHorizontalDragEnd: _onHorizontalDragEnd,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // 1. 次のページ（下層）
                              _buildPageView(_getUnderPageNumber()),

                              // 2. めくられるページ（完全垂直カット＋縦ロール影）
                              if (_dragProgress > 0.0)
                                _buildVerticalRollerEffect(_getTopPageNumber(), screenWidth),
                            ],
                          ),
                        ),
                      ),

                      // 下部スライダー
                      Container(
                        color: Colors.black87,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Slider(
                          value: _currentPage.toDouble(),
                          min: 1,
                          max: _totalPages.toDouble(),
                          divisions: _totalPages > 1 ? _totalPages - 1 : 1,
                          onChanged: (value) => _goToPage(value.toInt()),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  int _getTopPageNumber() => _currentPage;

  int _getUnderPageNumber() {
    if (_isNextPage) {
      return math.min(_currentPage + 1, _totalPages);
    } else {
      return math.max(_currentPage - 1, 1);
    }
  }

  Widget _buildPageView(int pageNum) {
    return FutureBuilder<ImageProvider>(
      future: _getPageImage(pageNum),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
          return SizedBox.expand(
            child: Image(
              image: snapshot.data!,
              fit: BoxFit.contain,
            ),
          );
        }
        return Container(color: Colors.white);
      },
    );
  }

  // 完全垂直なロールエフェクト描画
  Widget _buildVerticalRollerEffect(int pageNum, double screenWidth) {
    final isFromRight = (_isRightToLeft && _isNextPage) || (!_isRightToLeft && !_isNextPage);
    final progressWidth = screenWidth * _dragProgress;
    final remainWidth = screenWidth - progressWidth;

    final rollWidth = math.min(progressWidth, 60.0);

    return Stack(
      children: [
        // A. 残っている表面（完全垂直カット）
        ClipRect(
          clipper: VerticalStraightClipper(remainWidth: remainWidth, isFromRight: isFromRight),
          child: _buildPageView(pageNum),
        ),

        // B. 垂直な境界線の陰影
        Positioned(
          top: 0,
          bottom: 0,
          left: isFromRight ? remainWidth - 15 : remainWidth,
          width: 15,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isFromRight
                    ? [Colors.transparent, Colors.black.withOpacity(0.4)]
                    : [Colors.black.withOpacity(0.4), Colors.transparent],
              ),
            ),
          ),
        ),

        // C. 筒状ロール部分（垂直スライド）
        Positioned(
          top: 0,
          bottom: 0,
          left: isFromRight ? remainWidth : remainWidth - rollWidth,
          width: rollWidth,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.black.withOpacity(0.5),
                  Colors.white.withOpacity(0.35),
                  Colors.black.withOpacity(0.2),
                  Colors.black.withOpacity(0.6),
                ],
                stops: const [0.0, 0.25, 0.7, 1.0],
                begin: isFromRight ? Alignment.centerLeft : Alignment.centerRight,
                end: isFromRight ? Alignment.centerRight : Alignment.centerLeft,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 画面上部から下部まで完全に垂直（直線）に切り抜く
class VerticalStraightClipper extends CustomClipper<Rect> {
  final double remainWidth;
  final bool isFromRight;

  VerticalStraightClipper({required this.remainWidth, required this.isFromRight});

  @override
  Rect getClip(Size size) {
    if (isFromRight) {
      return Rect.fromLTWH(0, 0, remainWidth, size.height);
    } else {
      return Rect.fromLTWH(size.width - remainWidth, 0, remainWidth, size.height);
    }
  }

  @override
  bool shouldReclip(VerticalStraightClipper oldClipper) {
    return oldClipper.remainWidth != remainWidth || oldClipper.isFromRight != isFromRight;
  }
}
