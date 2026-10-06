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
  late PdfDocumentPinchController _pdfController;
  bool _isTwoPageMode = true; // 見開きモード
  bool _isRightToLeft = true; // 右開き（日本語漫画）モード

  @override
  void initState() {
    super.initState();
    // アセットまたはファイルからPDFを読み込み
    _pdfController = PdfDocumentPinchController(
      document: PdfDocument.openAsset('assets/manga.pdf'),
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
        title: const Text('漫画リーダー (見開き 3D表示)'),
        actions: [
          IconButton(
            icon: Icon(_isTwoPageMode ? Icons.book : Icons.single_bed),
            tooltip: '見開き切替',
            onPressed: () {
              setState(() {
                _isTwoPageMode = !_isTwoPageMode;
              });
            },
          ),
          IconButton(
            icon: Icon(_isRightToLeft ? Icons.swap_horiz : Icons.swap_horiz_sharp),
            tooltip: '開き方向切替',
            onPressed: () {
              setState(() {
                _isRightToLeft = !_isRightToLeft;
              });
            },
          ),
        ],
      ),
      body: Directionality(
        // 右開き（右から左へめくる）の設定
        textDirection: _isRightToLeft ? TextDirection.rtl : TextDirection.ltr,
        child: PdfViewPinch(
          controller: _pdfController,
          scrollDirection: Axis.horizontal,
          // ページ繰り時のシャドウ・めくり効果アニメーション
          builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
            options: const DefaultBuilderOptions(),
            documentLoaderBuilder: (_) => const Center(child: CircularProgressIndicator()),
            pageLoaderBuilder: (_) => const Center(child: CircularProgressIndicator()),
            errorBuilder: (_, error) => Center(child: Text(error.toString())),
          ),
        ),
      ),
    );
  }
}
