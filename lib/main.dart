import 'dart:async';
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const PdfReaderScreen(),
    );
  }
}

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key});

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  PdfDocument? _pdfDocument;
  bool _isLoading = true;
  String? _errorMessage;
  int _totalPages = 0;
  int _currentPage = 1;
  bool _isRightToLeft = false; // 右開き(RTL)かどうか

  @override
  void initState() {
    super.initState();
    _loadSamplePdf();
  }

  Future<void> _loadSamplePdf() async {
    try {
      // サンプルPDFのロード（必要に応じてURLを変更してください）
      final url = Uri.parse(
        'https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/web/compressed.tracemonkey-pldi-09.pdf',
      );
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final dir = await getTemporaryDirectory();
        final file = '${dir.path}/sample.pdf';
        final pdfFile = await Image.file(file).file.writeAsBytes(response.bodyBytes);
        final document = await PdfDocument.openFile(pdfFile.path);
        setState(() {
          _pdfDocument = document;
          _totalPages = document.pagesCount;
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'PDFのダウンロードに失敗しました (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'エラーが発生しました: $e';
        _isLoading = false;
      });
    }
  }

  void _nextPage() {
    if (_currentPage < _totalPages) {
      setState(() {
        _currentPage++;
      });
    }
  }

  void _previousPage() {
    if (_currentPage > 1) {
      setState(() {
        _currentPage--;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('PDF Reader (${_currentPage}/$_totalPages)'),
        actions: [
          IconButton(
            icon: Icon(_isRightToLeft ? Icons.format_textdirection_r_to_l : Icons.format_textdirection_l_to_r),
            tooltip: _isRightToLeft ? '右開き (RTL)' : '左開き (LTR)',
            onPressed: () {
              setState(() {
                _isRightToLeft = !_isRightToLeft;
              });
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : GestureDetector(
                  onHorizontalDragEnd: (details) {
                    if (details.primaryVelocity != null) {
                      if (details.primaryVelocity! < 0) {
                        // 左スワイプ
                        _isRightToLeft ? _previousPage() : _nextPage();
                      } else if (details.primaryVelocity! > 0) {
                        // 右スワイプ
                        _isRightToLeft ? _nextPage() : _previousPage();
                      }
                    }
                  },
                  child: Center(
                    child: PdfPageView(
                      pdfDocument: _pdfDocument!,
                      pageNumber: _currentPage,
                      isRightToLeft: _isRightToLeft,
                    ),
                  ),
                ),
      bottomNavigationBar: _pdfDocument != null
          ? BottomAppBar(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _currentPage > 1 ? _previousPage : null,
                  ),
                  Text('ページ $_currentPage / $_totalPages'),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _currentPage < _totalPages ? _nextPage : null,
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

class PdfPageView extends StatefulWidget {
  final PdfDocument pdfDocument;
  final int pageNumber;
  final bool isRightToLeft;

  const PdfPageView({
    super.key,
    required this.pdfDocument,
    required this.pageNumber,
    required this.isRightToLeft,
  });

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  PdfPageImage? _pageImage;
  bool _loadingPage = true;

  @override
  void initState() {
    super.initState();
    _renderPage();
  }

  @override
  void didUpdateWidget(covariant PdfPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageNumber != widget.pageNumber) {
      _renderPage();
    }
  }

  Future<void> _renderPage() async {
    setState(() {
      _loadingPage = true;
    });
    final page = await widget.pdfDocument.getPage(widget.pageNumber);
    final pageImage = await page.render(
      width: page.width * 2,
      height: page.height * 2,
      format: PdfPageImageFormat.jpeg,
    );
    await page.close();
    if (mounted) {
      setState(() {
        _pageImage = pageImage;
        _loadingPage = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPage || _pageImage == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return CustomPaint(
      painter: RealPageCurlPainter(
        isRightToLeft: widget.isRightToLeft,
      ),
      child: Image.memory(_pageImage!.bytes),
    );
  }
}

/// リアルなページめくり描画を行うCustomPainter
class RealPageCurlPainter extends CustomPainter {
  final bool _isRightToLeft;

  RealPageCurlPainter({
    required bool isRightToLeft,
  }) : _isRightToLeft = isRightToLeft;

  // 外部参照用のゲッターを追加（エラー回避）
  bool get isRightToLeft => _isRightToLeft;
  bool get _isRightToLeftGetter => _isRightToLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.05)
      ..style = PaintingStyle.fill;

    // ページの影（めくり効果の背景グラデーション）
    final shadowPath = Path();
    if (_isRightToLeft) {
      shadowPath.moveTo(0, 0);
      shadowPath.lineTo(20, 0);
      shadowPath.lineTo(0, size.height);
    } else {
      shadowPath.moveTo(size.width, 0);
      shadowPath.lineTo(size.width - 20, 0);
      shadowPath.lineTo(size.width, size.height);
    }
    shadowPath.close();

    canvas.drawPath(shadowPath, paint);
  }

  @override
  bool shouldRepaint(covariant RealPageCurlPainter oldDelegate) {
    return oldDelegate._isRightToLeft != _isRightToLeft;
  }
}
