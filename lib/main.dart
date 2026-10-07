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
  PdfControllerPinch? _pdfController;
  bool _isRightToLeft = true; // 日本の漫画用（右開き）
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  // ネットワークからPDFデータを取得してコントローラーを初期化
  Future<void> _loadPdf() async {
    try {
      final response = await http.get(
        Uri.parse('https://pdfobject.com/pdf/sample.pdf'),
      );

      if (response.statusCode == 200) {
        final Uint8List bytes = response.bodyBytes;
        setState(() {
          _pdfController = PdfControllerPinch(
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
      body: _buildBody(),
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
      // 右開き（右から左へスライド・めくる）設定
      textDirection: _isRightToLeft ? TextDirection.rtl : TextDirection.ltr,
      child: PdfViewPinch(
        controller: _pdfController!,
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
    );
  }
}
