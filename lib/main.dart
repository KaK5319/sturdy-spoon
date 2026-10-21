import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

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
  final String title;
  final List<String> pages; // アプリ内に保存した画像のパス
  int lastPage;

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'pages': pages, 'lastPage': lastPage};
  factory Book.fromJson(Map<String, dynamic> j) =>
      Book(j['id'], j['title'], List<String>.from(j['pages']), j['lastPage'] ?? 0);
}

/// 本の保存場所: アプリ専用フォルダ/books/<id>/0000.jpg ... と books.json
class Store {
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

  @override
  void initState() {
    super.initState();
    Store.load().then((l) {
      if (mounted) setState(() => _books.addAll(l));
    });
  }

  Future<void> _import() async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return;
    files.sort((a, b) => a.name.compareTo(b.name));
    setState(() => _busy = true);
    final book = await Store.addBook('本 ${_books.length + 1}', files);
    _books.add(book);
    await Store.save(_books);
    if (mounted) setState(() => _busy = false);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SideBooks')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
          ? const Center(child: Text('画像を選んで読み始めよう'))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, childAspectRatio: 0.62, crossAxisSpacing: 12, mainAxisSpacing: 12),
              itemCount: _books.length,
              itemBuilder: (_, i) {
                final b = _books[i];
                return GestureDetector(
                  onLongPress: () => _confirmDelete(b),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => Reader(book: b, onChanged: () => Store.save(_books)))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(File(b.pages.first),
                            fit: BoxFit.cover, width: double.infinity, cacheWidth: 400),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(b.title),
                    Text('${b.pages.length}ページ ・ ${b.lastPage + 1}ページ目まで',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ]),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _import, icon: const Icon(Icons.add), label: const Text('本を追加')),
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

  bool _rtl = true; // 右開き
  int _index = 0;
  int _mode = 0; // 0:停止 1:次へ -1:前へ
  double _progress = 0;
  double _acc = 0;
  double _tilt = 0; // -1:上をつまむ 〜 +1:下をつまむ
  Size _viewSize = Size.zero;

  final Map<int, ui.Image> _cache = {};
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
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
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
    return out;
  }

  void _sync(Size size, double dpr) {
    if (size != _cacheSize) {
      for (final i in _cache.values) {
        i.dispose();
      }
      _cache.clear();
      _loading.clear();
      _cacheSize = size;
    }
    final want = {for (var i = _index - 1; i <= _index + 1; i++) if (i >= 0 && i <= _last) i};
    _cache.removeWhere((k, v) {
      final drop = !want.contains(k);
      if (drop) v.dispose();
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

  void _onDragStart(DragStartDetails d) {
    if (_ac.isAnimating) return;
    _tilt = _tiltFromY(d.localPosition.dy); // つまんだ高さで折り目が傾く
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_ac.isAnimating) return;
    _tilt += (_tiltFromY(d.localPosition.dy) - _tilt) * 0.2; // 指の高さに追従する速さ(大きいほど素早い)
    _acc += d.delta.dx * _sgn;
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

  void _onDragEnd(DragEndDetails d) {
    if (_mode == 0) {
      _acc = 0;
      return;
    }
    final v = (d.primaryVelocity ?? 0) * _sgn; // 正:次へ方向(px/秒)
    final pv = _toProgress(v);                 // めくり量/秒
    if (_mode == 1) {
      _settle((_progress > _commitAt || v > _flickSpeed) ? 1 : 0, pv);
    } else {
      _settle((_progress < 1 - _commitAt || v < -_flickSpeed) ? 0 : 1, pv);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      backgroundColor: Colors.black,
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
              onHorizontalDragStart: _onDragStart,
              onHorizontalDragUpdate: _onDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onTapUp: (d) {
                _tilt = _tiltFromY(d.localPosition.dy);
                final x = d.localPosition.dx / size.width;
                if (x < 0.3) _flip(_rtl ? 1 : -1);
                if (x > 0.7) _flip(_rtl ? -1 : 1);
              },
              child: ready
                  ? CustomPaint(
                      painter: _CurlPainter(_shader!, cur, next, _mode == 0 ? 0 : _progress, _rtl, _tilt))
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
            child: Row(children: [
              IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black54),
                  onPressed: () => Navigator.pop(context)),
              const Spacer(),
              TextButton(
                  onPressed: () => setState(() => _rtl = !_rtl),
                  child: Text(_rtl ? '右開き' : '左開き', style: const TextStyle(color: Colors.black54))),
            ]),
          )),
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Text('${_index + 1} / ${_last + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black45, fontSize: 12)),
            ),
          ),
        ]);
      }),
    );
  }
}

class _CurlPainter extends CustomPainter {
  _CurlPainter(this.shader, this.cur, this.next, this.progress, this.rtl, this.tilt);
  final ui.FragmentShader shader;
  final ui.Image cur, next;
  final double progress;
  final bool rtl;
  final double tilt;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, progress)
      ..setFloat(3, rtl ? 1.0 : 0.0)
      ..setFloat(4, tilt)
      ..setImageSampler(0, cur)
      ..setImageSampler(1, next);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _CurlPainter old) => true;
}
