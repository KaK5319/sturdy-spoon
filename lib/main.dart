import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:page_flip/page_flip.dart';

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
  final GlobalKey<PageFlipWidgetState> _pageFlipKey = GlobalKey<PageFlipWidgetState>();
  PdfDocument? _pdfDocument;
  List<Widget> _pageWidgets = [];
  bool _isLoading = true;
  String? _errorMessage;
  int _currentPage = 1;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    _loadPdfAndPreparePages();
  }

  Future<void> _loadPdfAndPreparePages() async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/web/compressed.tracemonkey-pldi-09.pdf',
        ),
      );

      if (response.statusCode == 200) {
        final Uint8List bytes = response.bodyBytes;
        final doc = await PdfDocument.openData(bytes);
        _pdfDocument = doc;
        _totalPages = doc.pagesCount;

        // 各ページをPDFビュー描画用ウィジェットに変換
        List<Widget> pages = [];
        for (int i = 1; i <= doc.pagesCount; i++) {
          pages.add(
            Container(
              color: Colors.white,
              child: PdfPageView(
                controller: PdfPageController(
                  document: Future.value(doc),
                  initialPage: i,
                ),
              ),
            ),
          );
        }

        setState(() {
          _pageWidgets = pages;
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'PDFの取得に失敗しました (Status: ${response.statusCode})';
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
  void dispose() {
    _pdfDocument?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: Text('3D 漫画リーダー ($_currentPage/$_totalPages)'),
        backgroundColor: Colors.black,
      ),
      body: _buildBody(),
      bottomNavigationBar: Container(
        height: 60,
        color: Colors.black,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                _pageFlipKey.currentState?.previousPage();
              },
            ),
            Text(
              'ページ $_currentPage / $_totalPages',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: () {
                _pageFlipKey.currentState?.nextPage();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('PDFを読み込み・3Dページ作成中...'),
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

    return Directionality(
      // 右開き（右から左にめくる）
      textDirection: TextDirection.rtl,
      child: PageFlipWidget(
        key: _pageFlipKey,
        cutoff: 0.2, // めくり感度のしきい値
        children: _pageWidgets,
      ),
    );
  }
}
