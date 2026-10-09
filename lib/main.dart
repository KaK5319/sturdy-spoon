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
      title: 'Ultimate 3D Manga Curl',
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

class _MangaReaderScreenState extends State<MangaReaderScreen>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  List<ui.Image> _pageImages = [];
  bool _isLoading = true;
  String? _errorMessage;

  int _currentIndex = 0;
  double _dragProgress = 0.0;

  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        setState(() {
          _dragProgress = _animController.value;
        });
      });

    _loadShaderAndPdf();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadShaderAndPdf() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('shaders/page_curl.frag');
      _shader = program.fragmentShader();

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
      backgroundColor: const Color(0xFF555555), // 画面に馴染むダークグレー
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
            Text('最高画質レンダリング＆シェーダー構築中...',
                style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(_errorMessage!,
            style: const TextStyle(color: Colors.redAccent)),
      );
    }

    final currentImage = _pageImages[_currentIndex];
    final nextImage = (_currentIndex + 1 < _pageImages.length)
        ? _pageImages[_currentIndex + 1]
        : _pageImages[_currentIndex];

    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        setState(() {
          _dragProgress -=
              details.primaryDelta! / MediaQuery.of(context).size.width;
          _dragProgress = _dragProgress.clamp(0.0, 1.0);
        });
      },
      onHorizontalDragEnd: (details) {
        // フリック速度（弾いた速さ）を取得してスムーズに判定
        final velocity = details.primaryVelocity ?? 0.0;
        
        if (_dragProgress > 0.3 || velocity < -400) {
          // 速度が速い、または30%以上めくっていたら最後まで素早く滑らかに移動
          _animController
              .animateTo(1.0, curve: Curves.easeOutCubic)
              .then((_) {
            setState(() {
              if (_currentIndex + 1 < _pageImages.length) {
                _currentIndex++;
              }
              _dragProgress = 0.0;
            });
          });
        } else {
          // 満たない場合は吸い付くように元に戻る
          _animController.animateTo(0.0, curve: Curves.easeOutCubic);
        }
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
