import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';

void main() {
  runApp(const MangaReaderApp());
}

class MangaReaderApp extends StatelessWidget {
  const MangaReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '3D Cylinder Curl Reader',
      debugShowCheckedModeBanner: false,
      home: MangaReaderScreen(),
    );
  }
}

class MangaReaderScreen extends StatefulWidget {
  const MangaReaderScreen({super.key});

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen> {
  ui.FragmentShader? _shader;
  List<ui.Image> _pageImages = [];
  bool _isLoading = true;
  String? _errorMessage;

  int _currentIndex = 0;
  double _dragProgress = 0.0; // 0.0 〜 1.0

  @override
  void initState() {
    super.initState();
    _loadShaderAndPdf();
  }

  Future<void> _loadShaderAndPdf() async {
    try {
      // 1. シェーダーの読み込み
      final program = await ui.FragmentProgram.fromAsset('shaders/page_curl.frag');
      _shader = program.fragmentShader();

      // 2. PDFの読み込みとレンダリング
      final response = await http.get(
        Uri.parse(
          'https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/web/compressed.tracemonkey-pldi-09.pdf',
        ),
      );

      if (response.statusCode == 200) {
        final Uint8List bytes = response.bodyBytes;
        final document = await PdfDocument.openData(bytes);

        List<ui.Image> images = [];
        for (int i = 1; i <= document.pagesCount; i++) {
          final page = await document.getPage(i);
          final pageImage = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.jpeg,
          );
          await page.close();

          if (pageImage != null) {
            final codec = await ui.instantiateImageCodec(pageImage.bytes);
            final frame = await codec.getNextFrame();
            images.add(frame.image);
          }
        }
        await document.close();

        setState(() {
          _pageImages = images;
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'PDFの取得に失敗しました';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF6E6E6E),
      body: SafeArea(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('PDFおよびシェーダー読み込み中...', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
      );
    }

    final currentImage = _pageImages[_currentIndex];
    final nextImage = (_currentIndex + 1 < _pageImages.length)
        ? _pageImages[_currentIndex + 1]
        : _pageImages[_currentIndex];

    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        setState(() {
          // ドラッグ量に応じて進行度(0.0〜1.0)を更新
          _dragProgress -= details.primaryDelta! / MediaQuery.of(context).size.width;
          _dragProgress = _dragProgress.clamp(0.0, 1.0);
        });
      },
      onHorizontalDragEnd: (details) {
        setState(() {
          if (_dragProgress > 0.4 && _currentIndex + 1 < _pageImages.length) {
            _currentIndex++;
          }
          _dragProgress = 0.0;
        });
      },
      child: CustomPaint(
        size: Size.infinite,
        painter: PageCurlPainter(
          shader: _shader!,
          currentImage: currentImage,
          nextImage: nextImage,
          progress: _dragProgress,
        ),
      ),
    );
  }
}

class PageCurlPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final ui.Image currentImage;
  final ui.Image nextImage;
  final double progress;

  PageCurlPainter({
    required this.shader,
    required this.currentImage,
    required this.nextImage,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // シェーダーのパラメータを設定
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, progress);
    shader.setImageSampler(0, currentImage);
    shader.setImageSampler(1, nextImage);

    final paint = Paint()..shader = shader;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant PageCurlPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.currentImage != currentImage ||
        oldDelegate.nextImage != nextImage;
  }
}
