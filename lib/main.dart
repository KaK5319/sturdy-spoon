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

class _ShelfState extends State<Shelf> with TickerProviderStateMixin {
  final List<Book> _books = [];
  bool _busy = false;
  String _busyText = '';

  // 本棚: 2本指で広げる/つまむと、写真のように拡大縮小し、離すと1段の冊数が決まる ----------
  static const bool _spreadMakesMore = false; // false: 広げると大きくなる(写真と同じ) / true: 広げると増える
  static const int _minCols = 1, _maxCols = 5;
  static const double _pinchGain = 1.0;   // 1.0=指の開き具合と同じ割合で拡大(大きいほど敏感)
  static const double _frameW = 14;       // 左右の枠の太さ
  static const double _boardH = 29;       // 棚板の高さ
  final ScrollController _sc = ScrollController();
  final GlobalKey _shelfKey = GlobalKey();
  double _shelfW = 400, _shelfH = 800;
  int _n = 3;                              // 1段に並ぶ冊数(確定した値)
  int _pinchN = 3;                         // 2本指を置いた時点の冊数
  double _pinchScale = 1.0;                // 拡大中の倍率(1.0=そのまま)
  Offset _pinchStart = Offset.zero;        // 2本指を置いた真ん中(棚の中の位置)
  Offset _pinchMid = Offset.zero;          // 今の2本指の真ん中
  double _pinchOff0 = 0;                   // 2本指を置いた時点の、縦スクロールの位置
  int _focalIdx = 0;                       // 2本指の真ん中にある本
  double _focalRel = 0;                    // その本の段の中での縦の位置(0〜1)
  final Map<int, Offset> _ptrs = {};
  double? _pinchStartDist;
  bool _pinching = false;
  late final AnimationController _snap =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1.0);

  @override
  void dispose() {
    _sc.dispose();
    _fade.dispose();
    _snap.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _fade.addListener(() {
      if (mounted) setState(() {});
    });
    Store.load().then((l) {
      if (mounted) setState(() => _books.addAll(l));
    });
    Store.loadCols().then((c) {
      if (c != null && mounted) setState(() => _n = c.clamp(_minCols, _maxCols).toInt());
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

  double get _cellW => (_shelfW - _frameW * 2) / _n;
  double get _rowStride => _cellW / 0.7 + 10 + _boardH;

  Offset _midLocal() {
    final box = _shelfKey.currentContext?.findRenderObject() as RenderBox?;
    final v = _ptrs.values.toList();
    final mid = Offset((v[0].dx + v[1].dx) / 2, (v[0].dy + v[1].dy) / 2);
    return box?.globalToLocal(mid) ?? mid;
  }

  /// 2本指の真ん中にある本を覚えておく(確定したあと、その本が指のあたりに来るように)
  void _captureFocal() {
    final loc = _midLocal();
    _pinchStart = loc;
    _pinchMid = loc;
    final off = _sc.hasClients ? _sc.offset : 0.0;
    _pinchOff0 = off;
    final y = off + loc.dy;
    final stride = _rowStride;
    final r = (y / stride).floor().clamp(0, 100000).toInt();
    final col = ((loc.dx - _frameW) / _cellW).floor().clamp(0, _n - 1).toInt();
    _focalIdx = _books.isEmpty ? 0 : (r * _n + col).clamp(0, _books.length - 1).toInt();
    _focalRel = (y - r * stride) / stride;
  }

  /// 冊数が確定したあと、覚えておいた本が指のあたりに来るように、縦の位置を合わせる
  void _anchorAfterCommit() {
    if (!_sc.hasClients || _books.isEmpty) return;
    final stride = _rowStride;
    final r = _focalIdx ~/ _n;
    var off = r * stride + _focalRel * stride - _pinchStart.dy;
    final rows = (_books.length / _n).ceil();
    final rowCount = rows < 6 ? 6 : rows + 1;
    final maxOff = (rowCount * stride + 100 - _shelfH).clamp(0.0, 1e9).toDouble();
    off = off.clamp(0.0, maxOff).toDouble();
    _sc.jumpTo(off);
  }

  void _onPtrDown(PointerDownEvent e) {
    _ptrs[e.pointer] = e.position;
    if (_ptrs.length == 2) {
      _snap.stop();
      _pinchStartDist = _dist();
      _pinchN = _n;
      _pinchScale = 1.0;
      _captureFocal();
      setState(() => _pinching = true); // 2本指の間は、棚が勝手に動かないようにする
    }
  }

  void _onPtrMove(PointerMoveEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.position;
    final d0 = _pinchStartDist;
    if (_ptrs.length == 2 && d0 != null && d0 > 0) {
      final r = _dist() / d0; // >1: 広げた / <1: つまんだ
      final f = math.pow(_spreadMakesMore ? 1 / r : r, _pinchGain).toDouble();
      final lo = _pinchN / _maxCols, hi = _pinchN / _minCols;
      setState(() {
        _pinchScale = f.clamp(lo, hi).toDouble(); // 指の開きに合わせて、そのまま拡大縮小
        _pinchMid = _midLocal();                  // 指を動かせば、いっしょに動く
      });
    }
  }

  void _onPtrUp(PointerEvent e) {
    _ptrs.remove(e.pointer);
    if (_ptrs.length < 2 && _pinching) {
      _pinchStartDist = null;
      setState(() => _pinching = false);
      // 手を離したら、いちばん近い冊数の大きさへ、ふわっと吸い寄せる
      final n0 = _pinchN;
      final nt = (n0 / _pinchScale).round().clamp(_minCols, _maxCols).toInt();
      final from = _pinchScale;
      final to = n0 / nt;
      final tween = Tween<double>(begin: from, end: to).chain(CurveTween(curve: Curves.easeOutCubic));
      void tick() => setState(() => _pinchScale = tween.evaluate(_snap));
      _snap
        ..reset()
        ..addListener(tick);
      _snap.forward().whenComplete(() {
        _snap.removeListener(tick);
        if (!mounted) return;
        final changed = nt != n0;
        setState(() {
          _n = nt;
          _pinchScale = 1.0;
          _pinchMid = _pinchStart;
        });
        if (changed) {
          _anchorAfterCommit();
          _fade.forward(from: 0.0); // 並びが変わるときは、本をふわっと表示
        }
        Store.saveCols(nt);
      });
    }
  }

  /// 本棚の1冊分(表紙・タイトル・読んだ進捗)
  Widget _bookCell(Book b) {
    final titleSize = (22 / (_n / _pinchScale + 0.4)).clamp(9.0, 24.0).toDouble();
    final progress = b.pages.isEmpty ? 0.0 : (b.lastPage + 1) / b.pages.length;
    return Opacity(opacity: _fade.value, child: GestureDetector(
      onLongPress: () => _showBookMenu(b),
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => Reader(book: b, onChanged: () => Store.save(_books)))
        ).then((_) => setState(() {})), // 戻ったら進捗を更新
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
        child: AspectRatio(
          aspectRatio: 0.7,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              boxShadow: [
                BoxShadow(color: Color(0x99000000), blurRadius: 14, offset: Offset(5, 7)),
              ],
            ),
            child: Stack(alignment: Alignment.bottomCenter, children: [
              Positioned.fill(
                child: Image.file(File(b.pages.first),
                    fit: BoxFit.cover, alignment: Alignment.topCenter, cacheWidth: 700),
              ),
              // 表紙の左の縁にうっすら光(本の背のふくらみ)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.white.withOpacity(0.22), Colors.transparent, Colors.black.withOpacity(0.18)],
                      stops: const [0.0, 0.12, 1.0],
                    ),
                  ),
                ),
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
      ),
    ));
  }

  /// 棚板(上の面・手前の面・影)
  Widget _board() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        height: 8,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFE6B97D), Color(0xFFB98445)],
          ),
        ),
      ),
      SizedBox(
        height: 18,
        child: Stack(fit: StackFit.expand, children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF9C6532), Color(0xFF5B3716)],
              ),
            ),
          ),
          CustomPaint(painter: _WoodPainter(7, horizontal: true, strength: 0.22)),
        ]),
      ),
      Container(height: 3, color: const Color(0xFF241408)),
    ]);
  }

  /// 棚の1段ぶんの背景(奥の板・影・棚板)。ここには本を置かない=広げても動かない
  Widget _shelfRowBg(int r, double rowH) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: rowH,
        child: Stack(children: [
          // 棚の奥の板(縦の木目)
          Positioned.fill(
            child: Stack(fit: StackFit.expand, children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF4A2D14), Color(0xFF7A4B20)],
                  ),
                ),
              ),
              CustomPaint(painter: _WoodPainter(r + 1, strength: 0.16)),
            ]),
          ),
          // 上の棚板が落とす影
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 36,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.6), Colors.transparent],
                ),
              ),
            ),
          ),
        ]),
      ),
      _board(),
    ]);
  }

  /// 木の棚。棚(枠・板)は動かさず、本だけが拡大縮小する
  Widget _shelf() {
    const frame = _frameW; // 左右の枠の太さ
    return LayoutBuilder(builder: (context, box) {
      _shelfW = box.maxWidth;
      _shelfH = box.maxHeight;
      final inner = box.maxWidth - frame * 2;
      final n = _n;                   // 1段の冊数
      final cellW = inner / n;        // 本1冊の幅
      final rowH = cellW / 0.7 + 10;
      final stride = rowH + _boardH;
      final rows = (_books.length / n).ceil();
      final rowCount = rows < 6 ? 6 : rows + 1; // 空の段も見せる(縮めても下が空かないように多め)
      final contentH = rowCount * stride + 100;
      final bookH = (cellW - 12) / 0.7 + 10;

      // 広げている間は、棚の段(縦)と本が、同じ割合で拡大縮小する。
      // 棚の横幅は変わらない(左右の枠もそのまま)ので、まわりに空きができない。
      final sc = _pinchScale;
      final fx = _pinchStart.dx;                 // 2本指を置いた真ん中(横)
      final fy = _pinchOff0 + _pinchStart.dy;    // 2本指を置いた真ん中(縦・棚の中での位置)
      final mx = _pinchMid.dx;                   // 今の2本指の真ん中
      final my = _pinchOff0 + _pinchMid.dy;

      final rowsLayer = Transform(
        transform: Matrix4.identity()
          ..translate(0.0, my)
          ..scale(1.0, sc, 1.0)
          ..translate(0.0, -fy),
        child: Column(children: [for (var r = 0; r < rowCount; r++) _shelfRowBg(r, rowH)]),
      );

      final books = <Widget>[];
      for (var i = 0; i < _books.length; i++) {
        final r = i ~/ n, c = i % n;
        final bottom0 = r * stride + rowH;                         // 拡大前に乗っている棚板の位置
        final bottom = my + (bottom0 - fy) * sc;                   // 棚板といっしょに動く
        final w = cellW * sc;
        final cx = mx + (frame + c * cellW + cellW / 2 - fx) * sc; // 指の真ん中から横に広がる
        final h = (w - 12) / 0.7 + 10;
        books.add(Positioned(
          left: cx - w / 2,
          top: bottom - h,
          width: w,
          child: _bookCell(_books[i]),
        ));
      }

      final content = SizedBox(
        height: contentH,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(top: 0, left: 0, right: 0, child: rowsLayer),
          Positioned.fill(child: Stack(clipBehavior: Clip.none, children: books)),
        ]),
      );

      return Container(
        key: _shelfKey,
        color: const Color(0xFF2A1809),
        child: Stack(children: [
          SingleChildScrollView(
            controller: _sc,
            physics: (_pinching || _snap.isAnimating) ? const NeverScrollableScrollPhysics() : null,
            child: content,
          ),
          // 左右の枠(動かない)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: frame,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF1C0F05), Color(0xFF5E3815)]),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: frame,
            child: const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Color(0xFF5E3815), Color(0xFF1C0F05)]),
                ),
              ),
            ),
          ),
        ]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C0F05),
        title: const Text('SideBooks',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Color(0xFFF1D9B5))),
        actions: [
          IconButton(
            tooltip: '並べ替え',
            icon: const Icon(Icons.swap_vert, color: Color(0xFFF1D9B5)),
            onPressed: _books.length < 2
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReorderPage(books: _books, onChanged: () => Store.save(_books)),
                      ),
                    ).then((_) => setState(() {})),
          ),
        ],
      ),
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
              behavior: HitTestBehavior.translucent, // 棚のどこで2本指を置いても反応する
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


/// 木目を描く(縦または横の細い線を、決まった乱数でばらまく)
class _WoodPainter extends CustomPainter {
  _WoodPainter(this.seed, {this.horizontal = false, this.strength = 0.2});
  final int seed;
  final bool horizontal;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final p = Paint();
    final count = horizontal ? (size.height / 2.5).round() : (size.width / 5).round();
    for (var i = 0; i < count; i++) {
      final pos = rnd.nextDouble() * (horizontal ? size.height : size.width);
      final dark = rnd.nextBool();
      final op = rnd.nextDouble() * strength;
      p
        ..color = dark ? Color.fromRGBO(0, 0, 0, op) : Color.fromRGBO(255, 220, 170, op * 0.6)
        ..strokeWidth = 0.6 + rnd.nextDouble() * 1.6;
      final wobble = (rnd.nextDouble() - 0.5) * 8;
      if (horizontal) {
        canvas.drawLine(Offset(0, pos), Offset(size.width, pos + wobble * 0.3), p);
      } else {
        canvas.drawLine(Offset(pos, 0), Offset(pos + wobble, size.height), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WoodPainter old) => false;
}


/* ---------------- 並べ替え ---------------- */
class ReorderPage extends StatefulWidget {
  const ReorderPage({super.key, required this.books, required this.onChanged});
  final List<Book> books;
  final VoidCallback onChanged;
  @override
  State<ReorderPage> createState() => _ReorderPageState();
}

class _ReorderPageState extends State<ReorderPage> {
  @override
  Widget build(BuildContext context) {
    final books = widget.books;
    const ink = Color(0xFF111111);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: ink,
        title: const Text('並べ替え', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => books.sort((a, b) => natCompare(a.title, b.title)));
              widget.onChanged();
            },
            child: const Text('名前順に', style: TextStyle(color: Color(0xFF1565C0))),
          ),
        ],
      ),
      body: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        itemCount: books.length,
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex -= 1;
            final b = books.removeAt(oldIndex);
            books.insert(newIndex, b);
          });
          widget.onChanged();
        },
        itemBuilder: (c, i) {
          final b = books[i];
          return Padding(
            key: ValueKey(b.id),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: ListTile(
            tileColor: const Color(0xFFF2F2F2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            leading: SizedBox(
              width: 44,
              height: 62,
              child: Image.file(File(b.pages.first), fit: BoxFit.cover, cacheWidth: 200),
            ),
            title: Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: ink)),
            subtitle: Text('${b.pages.length}ページ', style: const TextStyle(color: Color(0xFF555555))),
            // 右の「≡」を指でつかんで、上下に動かす
            trailing: ReorderableDragStartListener(
              index: i,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle, color: Color(0xFF333333)),
              ),
            ),
          ));
        },
      ),
    );
  }
}
