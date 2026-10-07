import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

void main() {
  runApp(const MangaReaderApp());
}

class MangaReaderApp extends StatelessWidget {
  const MangaReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '3D Manga Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const MangaReaderScreen(),
    );
  }
}

class MangaReaderScreen extends StatefulWidget {
  const MangaReaderScreen({super.key});

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen> {
  late PdfControllerPinch _pdfController;
  bool _isRightToLeft = true; // 日本の漫画用（右開き）

  @override
  void initState() {
    super.initState();
    // ネット上のサンプルPDF、またはアセットPDFを読み込み
    _pdfController = PdfControllerPinch(
      document: PdfDocument.openData(
        InternetFile.get('https://pdfobject.com/pdf/sample.pdf'),
      ),
    );
  }

  @override
  void dispose() {
    _pdfController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: const Text('漫画リーダー'),
        actions: [
          IconButton(
            icon: Icon(_isRightToLeft ? Icons.swap_horiz : Icons.swap_horiz_sharp),
            tooltip: 'めくり方向切替',
            onPressed: () {
              setState(() {
                _isRightToLeft = !_isRightToLeft;
              });
            },
          ),
        ],
      ),
      body: Directionality(
        // 右開き（右から左へスライド・めくる）設定
        textDirection: _isRightToLeft ? TextDirection.rtl : TextDirection.ltr,
        child: PdfViewPinch(
          controller: _pdfController,
          scrollDirection: Axis.horizontal,
          builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
            options: const DefaultBuilderOptions(),
            documentLoaderBuilder: (_) =>
                const Center(child: CircularProgressIndicator()),
            pageLoaderBuilder: (_) =>
                const Center(child: CircularProgressIndicator()),
            errorBuilder: (_, error) =>
                Center(child: Text(error.toString())),
          ),
        ),
      ),
    );
  }
}
