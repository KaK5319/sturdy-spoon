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
    return MaterialApp(
      title: 'PDF Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
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
  PdfController? _pdfController;
  int _actualPage = 1;
  int _allPagesCount = 0;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  // 14ページある複数ページPDFを取得
  Future<void> _loadPdf() async {
    try {
      final response = await http.get(
        Uri.parse(
          'https://raw.githubusercontent.com/mozilla/pdf.js/ba2edeae/web/compressed.tracemonkey-pldi-09.pdf',
        ),
      );

      if (response.statusCode == 200) {
        final Uint8List bytes = response.bodyBytes;
        setState(() {
          _pdfController = PdfController(
            document: PdfDocument.openData(bytes),
          );
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage = 'PDFのダウンロードに失敗しました (Status: ${response.statusCode})';
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
    _pdfController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('PDF Reader ($_actualPage/$_allPagesCount)'),
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildBottomBar(),
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
            Text('PDFを読み込み中...'),
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
      // 右開き（右から左へめくる）設定
      textDirection: TextDirection.rtl,
      child: PdfView(
        controller: _pdfController!,
        scrollDirection: Axis.horizontal,
        onDocumentLoaded: (document) {
          setState(() {
            _allPagesCount = document.pagesCount;
          });
        },
        onPageChanged: (page) {
          setState(() {
            _actualPage = page;
          });
        },
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      height: 60,
      color: Colors.grey[100],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _pdfController == null
                ? null
                : () {
                    _pdfController!.previousPage(
                      curve: Curves.ease,
                      duration: const Duration(milliseconds: 300),
                    );
                  },
          ),
          Text(
            'ページ $_actualPage / $_allPagesCount',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: _pdfController == null
                ? null
                : () {
                    _pdfController!.nextPage(
                      curve: Curves.ease,
                      duration: const Duration(milliseconds: 300),
                    );
                  },
          ),
        ],
      ),
    );
  }
}
