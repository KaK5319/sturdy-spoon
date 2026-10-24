import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:archive/archive_io.dart' show InputFileStream;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' show PdfDocument, PdfPageImageFormat;
import 'package:rar/rar.dart' show Rar;

/// ページの外の背景色(page_curl.frag の BG と同じ明るさ)
const Color _bg = Color(0xFF1F1F1F);

void main() => runApp(const SideBooksApp());

class SideBooksApp extends StatelessWidget {
  const SideBooksApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SideBooks',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const Shelf(),
      );
}

class Book {
  Book(this.id, this.title, this.pages, [this.lastPage = 0]);
  final String id;
  String title; // 本棚で名前を変えられる
  final List<String> pages; // アプリ内に保存した画像のパス
  int lastPage;
  bool rtl = false; // この本の開き方(true=右開き / false=左開き)。最初は左開き

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'pages': pages, 'lastPage': lastPage, 'rtl': rtl};
  factory Book.fromJson(Map<String, dynamic> j) =>
      Book(j['id'], j['title'], List<String>.from(j['pages']), j['lastPage'] ?? 0)
        ..rtl = j['rtl'] ?? false;
}

/// 本の保存場所: アプリ専用フォルダ/books/<id>/0000.jpg ... と books.json
/// ファイル名の自然順(2 < 10)で並べる
int natCompare(String a, String b) {
  final re = RegExp(r'(\d+|\D+)');
  final pa = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final pb = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final nx = int.tryParse(pa[i]), ny = int.tryParse(pb[i]);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

bool _isImageName(String n) {
  final l = n.toLowerCase();
  return l.endsWith('.jpg') ||
      l.endsWith('.jpeg') ||
      l.endsWith('.png') ||
      l.endsWith('.webp') ||
      l.endsWith('.gif') ||
      l.endsWith('.bmp');
}

/// zip / cbz を展開して、画像だけをページ順に保存する(別スレッドで実行)
List<String> extractZip(List<String> args) {
  final zipPath = args[0], destDir = args[1];
  final input = InputFileStream(zipPath);
  final archive = ZipDecoder().decodeBuffer(input);
  final entries = archive.files
      .where((f) => f.isFile && _isImageName(f.name) && !f.name.contains('__MACOSX'))
      .toList()
    ..sort((a, b) => natCompare(a.name, b.name));
  final out = <String>[];
  for (var i = 0; i < entries.length; i++) {
    final name = entries[i].name;
    final ext = name.substring(name.lastIndexOf('.')).toLowerCase();
    final path = '$destDir/${i.toString().padLeft(4, '0')}$ext';
    File(path).writeAsBytesSync(entries[i].content as List<int>);
    out.add(path);
  }
  return out;
}

/// 展開済みフォルダの中から画像だけを集め、ページ順に番号を振って移す(別スレッドで実行)
List<String> collectImages(List<String> args) {
  final srcDir = args[0], destDir = args[1];
  final files = Directory(srcDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => _isImageName(f.path) && !f.path.contains('__MACOSX'))
      .toList()
    ..sort((a, b) => natCompare(a.path, b.path));
  final out = <String>[];
  for (var i = 0; i < files.length; i++) {
    final name = files[i].path;
    final ext = name.substring(name.lastIndexOf('.')).toLowerCase();
    final path = '$destDir/${i.toString().padLeft(4, '0')}$ext';
    files[i].renameSync(path);
    out.add(path);
  }
  return out;
}

/// ファイルの先頭を見て、本当の形式を調べる(拡張子が違っていても読めるように)
Future<String> sniffKind(String path) async {
  final raf = await File(path).open();
  final h = await raf.read(8);
  await raf.close();
  if (h.length >= 4 && h[0] == 0x50 && h[1] == 0x4B) return 'zip'; // PK
  if (h.length >= 4 && h[0] == 0x52 && h[1] == 0x61 && h[2] == 0x72 && h[3] == 0x21) return 'rar'; // Rar!
  if (h.length >= 4 && h[0] == 0x25 && h[1] == 0x50 && h[2] == 0x44 && h[3] == 0x46) return 'pdf'; // %PDF
  return 'unknown';
}

class Store {
  /// 新しい本用のフォルダを作る
  static Future<(String, Directory)> newBookDir() async {
    final d = await getApplicationDocumentsDirectory();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final dir = Directory('${d.path}/books/$id');
    await dir.create(recursive: true);
    return (id, dir);
  }

  /// PDFを1ページずつ画像にして保存する
  static Future<List<String>> importPdf(
      String pdfPath, Directory dir, void Function(int, int) onProgress) async {
    final doc = await PdfDocument.openFile(pdfPath);
    final paths = <String>[];
    try {
      final total = doc.pagesCount;
      for (var i = 1; i <= total; i++) {
        final page = await doc.getPage(i);
        try {
          final scale = 1600 / page.width; // 横1600pxくらいで保存
          final img = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: PdfPageImageFormat.jpeg,
            backgroundColor: '#FFFFFF',
            quality: 90,
          );
          if (img != null) {
            final path = '${dir.path}/${(i - 1).toString().padLeft(4, '0')}.jpg';
            await File(path).writeAsBytes(img.bytes);
            paths.add(path);
          }
        } finally {
          await page.close();
        }
        onProgress(i, total);
      }
    } finally {
      await doc.close();
    }
    return paths;
  }

  static Future<File> _index() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/books.json');
  }

  static Future<List<Book>> load() async {
    try {
      final f = await _index();
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return list
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .where((b) => b.pages.isNotEmpty && File(b.pages.first).existsSync())
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<File> _colsFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/shelf_cols.txt');
  }

  static Future<int?> loadCols() async {
    try {
      final f = await _colsFile();
      if (!await f.exists()) return null;
      return int.tryParse((await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveCols(int n) async {
    try {
      await (await _colsFile()).writeAsString('$n');
    } catch (_) {}
  }

  static Future<void> save(List<Book> books) async {
    final f = await _index();
    await f.writeAsString(jsonEncode(books.map((b) => b.toJson()).toList()));
  }

  static Future<Book> addBook(String title, List<XFile> files) async {
    final d = await getApplicationDocumentsDirectory();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final dir = Directory('${d.path}/books/$id');
    await dir.create(recursive: true);
    final paths = <String>[];
    for (var i = 0; i < files.length; i++) {
      final name = files[i].name;
      final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '.jpg';
      final dest = '${dir.path}/${i.toString().padLeft(4, '0')}$ext';
      await File(files[i].path).copy(dest);
      paths.add(dest);
    }
    return Book(id, title, paths);
  }

  static Future<void> deleteBook(Book b) async {
    final d = await getApplicationDocumentsDirectory();
    final dir = Directory('${d.path}/books/${b.id}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/* ---------------- 本棚 ---------------- */
class Shelf extends StatefulWidget {
  const Shelf({super.key});
  @override
  State<Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<Shelf> {
  final List<Book> _books = [];
  bool _busy = false;
  String _busyText = '';

  // 本棚: 2本指で広げる/つまむと、1段に並ぶ本の数が変わる ----------------
  static const bool _spreadMakesMore = true; // true: 広げると増える / false: 広げると大きくなる(減る)
  static const int _minCols = 1, _maxCols = 5;
  int _cols = 3;
  final Map<int, Offset> _ptrs = {};
  double? _pinchStartDist;
  int _pinchStartCols = 3;
  bool _pinching = false;

  @override
  void initState() {
    super.initState();
    Store.load().then((l) {
      if (mounted) setState(() => _books.addAll(l));
    });
    Store.loadCols().then((c) {
      if (c != null && mounted) setState(() => _cols = c.clamp(_minCols, _maxCols).toInt());
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('写真から追加'),
            onTap: () {
              Navigator.pop(c);
              _importImages();
            },
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf),
            title: const Text('PDF・zip・cbz・rar・cbr から追加'),
            onTap: () {
              Navigator.pop(c);
              _importFile();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _importImages() async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return;
    files.sort((a, b) => natCompare(a.name, b.name));
    setState(() {
      _busy = true;
      _busyText = '保存中…';
    });
    final book = await Store.addBook('本 ${_books.length + 1}', files);
    _books.add(book);
    await Store.save(_books);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _importFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    final path = f.path;
    if (path == null) return _snack('ファイルを読み込めませんでした');
    final dot = f.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : f.name.substring(dot + 1).toLowerCase();
    final title = dot < 0 ? f.name : f.name.substring(0, dot);
    if (!['pdf', 'cbz', 'zip', 'rar', 'cbr'].contains(ext)) {
      return _snack('PDF・zip・cbz・rar・cbr のファイルを選んでください');
    }

    setState(() {
      _busy = true;
      _busyText = '読み込み中…';
    });
    final (id, dir) = await Store.newBookDir();
    try {
      // 拡張子ではなく、中身で形式を判断する(.cbr でも実はzipということが多い)
      var kind = await sniffKind(path);
      if (kind == 'unknown') kind = (ext == 'pdf') ? 'pdf' : ((ext == 'rar' || ext == 'cbr') ? 'rar' : 'zip');

      final List<String> paths;
      if (kind == 'pdf') {
        paths = await Store.importPdf(path, dir, (i, n) {
          if (mounted) setState(() => _busyText = '変換中 $i / $n ページ');
        });
      } else if (kind == 'rar') {
        if (mounted) setState(() => _busyText = 'RARを展開中…(少し時間がかかります)');
        final tmp = Directory('${dir.path}/_rar');
        await tmp.create(recursive: true);
        final r = await Rar.extractRarFile(rarFilePath: path, destinationPath: tmp.path);
        if (r['success'] != true) throw (r['message'] ?? 'RARを展開できませんでした');
        paths = await compute(collectImages, [tmp.path, dir.path]);
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } else {
        if (mounted) setState(() => _busyText = '展開中…(少し時間がかかります)');
        paths = await compute(extractZip, [path, dir.path]);
      }
      if (paths.isEmpty) throw '画像が見つかりませんでした';
      _books.add(Book(id, title, paths));
      await Store.save(_books);
    } catch (e) {
      if (await dir.exists()) await dir.delete(recursive: true);
      _snack('読み込めませんでした: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showBookMenu(Book b) {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('名前を変更'),
            onTap: () {
              Navigator.pop(c);
              _rename(b);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('削除'),
            onTap: () {
              Navigator.pop(c);
              _confirmDelete(b);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _rename(Book b) async {
    final name = await showDialog<String>(
      context: context,
      builder: (c) => _RenameDialog(initial: b.title),
    );
    if (name == null || name.isEmpty) return;
    setState(() => b.title = name);
    await Store.save(_books);
  }

  Future<void> _confirmDelete(Book b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('「${b.title}」を削除しますか?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('削除')),
        ],
      ),
    );
    if (ok != true) return;
    await Store.deleteBook(b);
    setState(() => _books.remove(b));
    await Store.save(_books);
  }

  double _dist() {
    final v = _ptrs.values.toList();
    return (v[0] - v[1]).distance;
  }

  void _onPtrDown(PointerDownEvent e) {
    _ptrs[e.pointer] = e.position;
    if (_ptrs.length == 2) {
      _pinchStartDist = _dist();
      _pinchStartCols = _cols;
      setState(() => _pinching = true); // 2本指の間は、棚が勝手に動かないようにする
    }
  }

  void _onPtrMove(PointerMoveEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.position;
    final d0 = _pinchStartDist;
    if (_ptrs.length == 2 && d0 != null && d0 > 0) {
      final r = _dist() / d0; // >1: 広げた / <1: つまんだ
      final f = _spreadMakesMore ? r : 1 / r;
      final nc = (_pinchStartCols * f).round().clamp(_minCols, _maxCols).toInt();
      if (nc != _cols) setState(() => _cols = nc);
    }
  }

  void _onPtrUp(PointerEvent e) {
    _ptrs.remove(e.pointer);
    if (_ptrs.length < 2 && _pinching) {
      _pinchStartDist = null;
      setState(() => _pinching = false);
      Store.saveCols(_cols);
    }
  }

  /// 本棚の1冊分(表紙・タイトル・読んだ進捗)
  Widget _bookCell(Book b) {
    final titleSize = _cols <= 1 ? 20.0 : (_cols == 2 ? 15.0 : (_cols == 3 ? 12.0 : 10.0));
    final progress = b.pages.isEmpty ? 0.0 : (b.lastPage + 1) / b.pages.length;
    return GestureDetector(
      onLongPress: () => _showBookMenu(b),
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => Reader(book: b, onChanged: () => Store.save(_books)))
        ).then((_) => setState(() {})), // 戻ったら進捗を更新
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
        child: AspectRatio(
          aspectRatio: 0.7,
          child: Stack(alignment: Alignment.bottomCenter, children: [
            Positioned.fill(
              child: Image.file(File(b.pages.first),
                  fit: BoxFit.cover, alignment: Alignment.topCenter, cacheWidth: 700),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: const Color(0xAA000000),
                padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(b.title,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white, fontSize: titleSize)),
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.white24,
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// 木の棚の見た目で、1段ずつ並べる
  Widget _shelf() {
    final rows = (_books.length / _cols).ceil();
    final rowCount = rows < 4 ? 4 : rows + 1; // 空の段も見せる
    return Container(
      color: const Color(0xFF7A4A1E),
      child: ListView.builder(
        physics: _pinching ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.only(bottom: 90),
        itemCount: rowCount,
        itemBuilder: (_, r) {
          final cells = <Widget>[];
          for (var c = 0; c < _cols; c++) {
            final i = r * _cols + c;
            cells.add(Expanded(child: i < _books.length ? _bookCell(_books[i]) : const SizedBox()));
          }
          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF8A5624), Color(0xFF6E4119)],
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: cells),
              // 棚板
              Container(
                height: 16,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFC98A4B), Color(0xFF8B5A2B)],
                  ),
                       border: Border(bottom: BorderSide(color: Color(0xFF3E2410), width: 3)),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SideBooks')),
      body: _busy
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_busyText),
              ]),
            )
          : _books.isEmpty
          ? const Center(child: Text('写真・PDF・zip を選んで読み始めよう'))
          : Listener(
              onPointerDown: _onPtrDown,
              onPointerMove: _onPtrMove,
              onPointerUp: _onPtrUp,
              onPointerCancel: _onPtrUp,
              child: _shelf(),
            ),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _showAddMenu, icon: const Icon(Icons.add), label: const Text('本を追加')),
    );
  }
}

/* ---------------- リーダー ---------------- */
class Reader extends StatefulWidget {
  const Reader({super.key, required this.book, this.onChanged});
  final Book book;
  final VoidCallback? onChanged;
  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final AnimationController _ac = AnimationController(vsync: this);

  // 指に吸い付く感じの調整 ------------------------------
  static const double _pull = 1.2;        // めくりの軽さ。小さいほど指に吸い付く(1.0=指と同じ速さ)。軽くしたいなら1.5
  static const double _curlR = 0.07;      // 巻きの半径(シェーダーの R_REL と同じ値)
  static const double _stiffness = 340;   // 大きいほど離した瞬間にキュッと吸い寄せる
  static const double _damping = 34;      // 大きいほど揺れずに落ち着く

  // めくりやすさの調整 ----------------------------------
  static const double _commitAt = 0.15;   // ここまで動かして離せばめくれる(小さいほど軽い。0.5だと半分まで)
  static const double _flickSpeed = 150;  // 軽く払う速さ(px/秒)。小さいほど軽い払いでめくれる

  late bool _rtl = widget.book.rtl; // この本で最後に選んだ開き方(初めては左開き)
  int _index = 0;
  int _mode = 0; // 0:停止 1:次へ -1:前へ
  double _progress = 0;
  double _acc = 0;
  double _tilt = 0; // -1:上をつまむ 〜 +1:下をつまむ
  Size _viewSize = Size.zero;

  // ピンチズーム ------------------------------------------
  static const double _maxZoom = 4.0;     // 最大の拡大率
  static const double _doubleTapZoom = 2.5; // ダブルタップで拡大する倍率
  double _zoom = 1.0;
  Offset _offset = Offset.zero;
  double _startZoom = 1.0;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  bool _pinching = false;
  DateTime _lastTap = DateTime(2000);

  // メニュー(中央を1回タップで表示/非表示) ---------------------
  bool _ui = false;
  Timer? _uiTimer;
  int? _dragPage; // スライダーをつまんでいる間のページ番号(1始まり)
  ui.Image? _hi; // 拡大用の高解像度画像
  bool _hiLoading = false;

  final Map<int, ui.Image> _cache = {};
  final Map<int, Rect> _rects = {}; // 各ページの大きさ(画面上の位置)。この中だけがめくれる
  final Set<int> _loading = {};
  Size _cacheSize = Size.zero;

  int get _last => widget.book.pages.length - 1;
  double get _sgn => _rtl ? 1.0 : -1.0; // 「次へ」方向のドラッグ符号

  @override
  void initState() {
    super.initState();
    _index = widget.book.lastPage.clamp(0, widget.book.pages.length - 1);
    ui.FragmentProgram.fromAsset('shaders/page_curl.frag')
        .then((p) => mounted ? setState(() => _shader = p.fragmentShader()) : null);
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _hi?.dispose();
    _ac.dispose();
    for (final i in _cache.values) {
      i.dispose();
    }
    super.dispose();
  }

  /* ---- 画像の読み込み(画面サイズに合わせて白背景で中央配置) ---- */
  Future<ui.Image> _load(int i, Size size, double dpr) async {
    final bytes = await File(widget.book.pages[i]).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: (size.width * dpr).round());
    final src = (await codec.getNextFrame()).image;
    final w = size.width * dpr, h = size.height * dpr;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = _bg);
    final s = math.min(w / src.width, h / src.height);
    final dw = src.width * s, dh = src.height * s;
    c.drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final out = await rec.endRecording().toImage(w.round(), h.round());
    src.dispose();
    _rects[i] = Rect.fromLTWH((w - dw) / 2 / dpr, (h - dh) / 2 / dpr, dw / dpr, dh / dpr);
    return out;
  }

  void _sync(Size size, double dpr) {
    if (size != _cacheSize) {
      for (final i in _cache.values) {
        i.dispose();
      }
      _cache.clear();
      _rects.clear();
      _loading.clear();
      _cacheSize = size;
    }
    final want = {for (var i = _index - 1; i <= _index + 1; i++) if (i >= 0 && i <= _last) i};
    _cache.removeWhere((k, v) {
      final drop = !want.contains(k);
      if (drop) {
        v.dispose();
        _rects.remove(k);
      }
      return drop;
    });
    for (final i in want) {
      if (_cache.containsKey(i) || _loading.contains(i)) continue;
      _loading.add(i);
      _load(i, size, dpr).then((img) {
        _loading.remove(i);
        if (!mounted || size != _cacheSize) {
          img.dispose();
          return;
        }
        setState(() => _cache[i] = img);
      });
    }
  }

  /* ---- めくり操作 ---- */
  void _settle(double target, [double velocity = 0]) {
    final m = _mode;
    _ac.stop();
    void tick() => setState(() => _progress = _ac.value);
    _ac.addListener(tick);
    _ac
        .animateWith(SpringSimulation(
            const SpringDescription(mass: 1, stiffness: _stiffness, damping: _damping),
            _progress,
            target,
            velocity))
        .whenComplete(() {
      _ac.removeListener(tick);
      if (!mounted) return;
      final committed = (m == 1 && target == 1) || (m == -1 && target == 0);
      setState(() {
        if (m == 1 && target == 1) _index++;
        if (m == -1 && target == 0) _index--;
        _mode = 0;
        _progress = 0;
        _acc = 0;
      });
      if (committed) HapticFeedback.selectionClick(); // めくれた瞬間にコツッ
      widget.book.lastPage = _index;
      widget.onChanged?.call();
    });
  }

  /// 指の移動量(px) → めくり量(0〜1)。傾きに関係なく、画面の幅だけ動かせばめくり切れる
  double _toProgress(double px) => px / (_viewSize.width * (1 + _curlR)) * _pull;

  double _tiltFromY(double y) => ((y / _viewSize.height) * 2 - 1).clamp(-1.0, 1.0);

  /// スライダーなどから好きなページへ移動
  void _jumpTo(int i) {
    if (_ac.isAnimating) return;
    final n = i.clamp(0, _last).toInt();
    setState(() {
      _index = n;
      _mode = 0;
      _progress = 0;
      _acc = 0;
    });
    widget.book.lastPage = n;
    widget.onChanged?.call();
  }

  void _flip(int dir) {
    if (_mode != 0 || _ac.isAnimating) return;
    if (dir == 1 && _index < _last) {
      setState(() {
        _mode = 1;
        _progress = 0;
      });
      _settle(1);
    } else if (dir == -1 && _index > 0) {
      setState(() {
        _mode = -1;
        _progress = 1;
      });
      _settle(0);
    }
  }

  /* ---- ピンチズーム ---- */
  Offset _clampOffset(Offset o, double z) {
    final w = _viewSize.width, h = _viewSize.height;
    return Offset(o.dx.clamp(w - w * z, 0.0).toDouble(), o.dy.clamp(h - h * z, 0.0).toDouble());
  }

  Future<void> _ensureHi() async {
    if (_hi != null || _hiLoading) return;
    _hiLoading = true;
    final idx = _index;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final targetW = (_viewSize.width * dpr * 3).round();
    try {
      final bytes = await File(widget.book.pages[idx]).readAsBytes();
      final codec =
          await ui.instantiateImageCodec(bytes, targetWidth: targetW, allowUpscaling: false);
      final img = (await codec.getNextFrame()).image;
      if (!mounted || _zoom <= 1.001 || idx != _index) {
        img.dispose();
      } else {
        setState(() => _hi = img);
      }
    } finally {
      _hiLoading = false;
    }
  }

  void _resetZoom() {
    final old = _hi;
    setState(() {
      _zoom = 1.0;
      _offset = Offset.zero;
      _hi = null;
    });
    // 描画が終わってから解放する
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _zoomAt(Offset p) {
    setState(() {
      _zoom = _doubleTapZoom;
      _offset = _clampOffset(p - p * _doubleTapZoom, _doubleTapZoom);
    });
    _ensureHi();
  }

  /* ---- 1本指=めくり / 2本指=ズーム / 拡大中の1本指=移動 ---- */
  void _onScaleStart(ScaleStartDetails d) {
    _uiTimer?.cancel();
    if (_ui) setState(() => _ui = false); // めくり・拡大を始めたらメニューを消す
    _startZoom = _zoom;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
    _pinching = (d.pointerCount >= 2 || _zoom > 1.001) && _mode == 0 && !_ac.isAnimating;
    if (!_pinching && !_ac.isAnimating && _mode == 0) {
      _tilt = _tiltFromY(d.localFocalPoint.dy); // つまんだ高さで折り目が傾く
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_ac.isAnimating) return;

    if (_pinching) {
      final z = (_startZoom * d.scale).clamp(1.0, _maxZoom).toDouble();
      final c = (_startFocal - _startOffset) / _startZoom; // 指の下にあるページ上の点
      setState(() {
        _zoom = z;
        _offset = z <= 1.0 ? Offset.zero : _clampOffset(d.localFocalPoint - c * z, z);
      });
      if (z > 1.001) _ensureHi();
      return;
    }

    if (d.pointerCount > 1) return; // めくり中に指が増えても無視
    _tilt += (_tiltFromY(d.localFocalPoint.dy) - _tilt) * 0.2; // 指の高さに追従する速さ
    _acc += d.focalPointDelta.dx * _sgn;
    if (_mode == 0) {
      if (_acc > 8 && _index < _last) {
        _mode = 1;
      } else if (_acc < -8 && _index > 0) {
        _mode = -1;
      } else {
        return;
      }
    }
    setState(() {
      final a = _toProgress(_acc);
      _progress = (_mode == 1 ? a : 1 + a).clamp(0.0, 1.0);
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_pinching) {
      _pinching = false;
      if (_zoom < 1.05) _resetZoom(); // ほぼ等倍なら元に戻す
      return;
    }
    if (_mode == 0) {
      _acc = 0;
      return;
    }
    final v = d.velocity.pixelsPerSecond.dx * _sgn; // 正:次へ方向(px/秒)
    final pv = _toProgress(v);                      // めくり量/秒
    if (_mode == 1) {
      _settle((_progress > _commitAt || v > _flickSpeed) ? 1 : 0, pv);
    } else {
      _settle((_progress < 1 - _commitAt || v < -_flickSpeed) ? 0 : 1, pv);
    }
  }

  /* ---- メニュー(上のバー) ---- */
  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: const Color(0xE6222222),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: SafeArea(
          bottom: false,
          child: Row(children: [
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
              child: const Text('戻る'),
            ),
            Expanded(
              child: Text(widget.book.title,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 64),
          ]),
        ),
      ),
    );
  }

  /* ---- メニュー(下のパネル: ページ数・スライダー・左右ボタン) ---- */
  Widget _buildBottomPanel() {
    final total = widget.book.pages.length;
    final shown = _dragPage ?? (_index + 1);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: const Color(0xE6222222),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$shown / $total',
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
            // 右開きのときは、スライダーも右が1ページ目になる
            Directionality(
              textDirection: _rtl ? TextDirection.rtl : TextDirection.ltr,
              child: Slider(
                min: 1,
                max: total < 2 ? 2 : total.toDouble(),
                divisions: total < 2 ? null : total - 1,
                value: shown.clamp(1, total < 2 ? 2 : total).toDouble(),
                onChanged: total < 2 ? null : (v) => setState(() => _dragPage = v.round()),
                onChangeEnd: (v) {
                  setState(() => _dragPage = null);
                  _jumpTo(v.round() - 1);
                },
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              // 画面の左右のタップと同じ向きに動く
              IconButton(
                  icon: const Icon(Icons.arrow_left, size: 40, color: Colors.white),
                  onPressed: () => _flip(_rtl ? 1 : -1)),
              OutlinedButton(
                onPressed: () {
                  setState(() => _rtl = !_rtl);
                  widget.book.rtl = _rtl; // 次に開いたときも同じ向きになる
                  widget.onChanged?.call();
                },
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                child: Text(_rtl ? '右開き(右▶左)' : '左開き(左▶右)'),
              ),
              IconButton(
                  icon: const Icon(Icons.arrow_right, size: 40, color: Colors.white),
                  onPressed: () => _flip(_rtl ? -1 : 1)),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      backgroundColor: _bg,
      body: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        _viewSize = size;
        _sync(size, dpr);

        final curIdx = _mode == -1 ? _index - 1 : _index;
        final nextIdx = _mode == 1 ? _index + 1 : _index;
        final cur = _cache[curIdx];
        final next = _cache[nextIdx];
        final ready = _shader != null && cur != null && next != null;

        return Stack(fit: StackFit.expand, children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              onTapUp: (d) {
                final now = DateTime.now();
                final isDouble = now.difference(_lastTap).inMilliseconds < 300;
                _lastTap = now;
                final x = d.localPosition.dx / size.width;
                final center = x >= 0.3 && x <= 0.7;
                if (_zoom > 1.001) {
                  if (isDouble) {
                    _uiTimer?.cancel();
                    _resetZoom(); // 拡大中のダブルタップで等倍に戻る
                  }
                  return;
                }
                if (center) {
                  _uiTimer?.cancel();
                  if (isDouble) {
                    _zoomAt(d.localPosition); // 中央のダブルタップで拡大
                  } else {
                    // 1回タップ: ダブルタップでないと分かってからメニューを出す
                    _uiTimer = Timer(const Duration(milliseconds: 300), () {
                      if (mounted) setState(() => _ui = !_ui);
                    });
                  }
                  return;
                }
                _tilt = _tiltFromY(d.localPosition.dy);
                if (_ui) setState(() => _ui = false); // 端をタップしてめくるときもメニューを消す
                if (x < 0.3) _flip(_rtl ? 1 : -1);
                if (x > 0.7) _flip(_rtl ? -1 : 1);
              },
              child: ready
                  ? CustomPaint(
                      painter: (_zoom > 1.001 && _mode == 0)
                          ? _ZoomPainter(_hi ?? cur, _hi == null, _zoom, _offset)
                          : _CurlPainter(_shader!, cur, next, _mode == 0 ? 0 : _progress, _rtl, _tilt,
                              _rects[curIdx] ?? (Offset.zero & size), _rects[nextIdx] ?? (Offset.zero & size)))
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          if (_ui) _buildTopBar(),
          if (_ui) _buildBottomPanel(),
        ]);
      }),
    );
  }
}

class _CurlPainter extends CustomPainter {
  _CurlPainter(this.shader, this.cur, this.next, this.progress, this.rtl, this.tilt, this.curRect, this.nextRect);
  final ui.FragmentShader shader;
  final ui.Image cur, next;
  final double progress;
  final bool rtl;
  final double tilt;
  final Rect curRect, nextRect;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, progress)
      ..setFloat(3, rtl ? 1.0 : 0.0)
      ..setFloat(4, tilt)
      ..setFloat(5, curRect.left)
      ..setFloat(6, curRect.top)
      ..setFloat(7, curRect.width)
      ..setFloat(8, curRect.height)
      ..setFloat(9, nextRect.left)
      ..setFloat(10, nextRect.top)
      ..setFloat(11, nextRect.width)
      ..setFloat(12, nextRect.height)
      ..setImageSampler(0, cur)
      ..setImageSampler(1, next);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _CurlPainter old) => true;
}


/// 拡大表示用。高解像度画像があればそれを、無ければ画面サイズの画像を拡大して描く
class _ZoomPainter extends CustomPainter {
  _ZoomPainter(this.img, this.fitted, this.zoom, this.offset);
  final ui.Image img;
  final bool fitted; // true: 画面サイズに整形済みの画像
  final double zoom;
  final Offset offset;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(zoom);
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    Rect dst;
    if (fitted) {
      dst = Offset.zero & size;
    } else {
      canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
      final sc = math.min(size.width / img.width, size.height / img.height);
      final dw = img.width * sc, dh = img.height * sc;
      dst = Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh);
    }
    canvas.drawImageRect(img, src, dst, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ZoomPainter old) => true;
}


/// 名前の変更ダイアログ(入力欄は、このダイアログが閉じるときに片付ける)
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本の名前を変更'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '本の名前'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('やめる')),
        TextButton(onPressed: () => Navigator.pop(context, _ctrl.text.trim()), child: const Text('保存')),
      ],
    );
  }
}             
