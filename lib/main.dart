import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:curl_page_view/curl_page_view.dart';

void main() {
  runApp(const MangaReaderApp());
}

class MangaReaderApp extends StatelessWidget {
  const MangaReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: '3D Manga Curl Reader',
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
  List<Widget> _pageImages = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPdfAndRenderImages();
  }

  Future<void> _loadPdfAndRenderImages() async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/web/compressed.tracemonkey-pldi-09.pdf',
        ),
      );

      if (response.statusCode == 200) {
        final Uint8List bytes = response.bodyBytes;
        final document = await PdfDocument.openData(bytes);

        List<Widget> pageWidgets = [];
        for (int i = 1; i <= document.pagesCount; i++) {
          final page = await document.getPage(i);
          final pageImage = await page.render(
            width: page.width * 2,
            height: page.height * 2,
            format: PdfPageImageFormat.jpeg,
          );
          await page.close();

          if (pageImage != null) {
            pageWidgets.add(
              Container(
                color: Colors.white,
                width: double.infinity,
                height: double.infinity,
                child: Image.memory(
                  pageImage.bytes,
                  fit: BoxFit.contain,
                ),
              ),
            );
          }
        }
        await document.close();

        setState(() {
          _pageImages = pageWidgets;
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
      backgroundColor: const Color(0xFF6E6E6E), // 画像のようなグレーの背景色
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
            Text(
              'PDF読み込み中...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: const TextStyle(color: Colors.redAccent),
        ),
      );
    }

    return CurlPageView(
      children: _pageImages,
      isVertical: false,
    );
  }
}
