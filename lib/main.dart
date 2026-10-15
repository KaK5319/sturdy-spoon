import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

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
  Book(this.title, this.pages);
  final String title;
  final List<XFile> pages;
}

/* ---------------- 本棚 ---------------- */
class Shelf extends StatefulWidget {
  const Shelf({super.key});
  @override
  State<Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<Shelf> {
  final List<Book> _books = [];

  Future<void> _import() async {
    final files = await ImagePicker().pickMultiImage();
    if (files.isEmpty) return;
    files.sort((a, b) => a.name.compareTo(b.name));
    setState(() => _books.add(Book('本 ${_books.length + 1}', files)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SideBooks')),
      body: _books.isEmpty
          ? const Center(child: Text('画像を選んで読み始めよう'))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, childAspectRatio: 0.62, crossAxisSpacing: 12, mainAxisSpacing: 12),
              itemCount: _books.length,
              itemBuilder: (_, i) {
                final b = _books[i];
                return GestureDetector(
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => Reader(book: b))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: FutureBuilder<Uint8List>(
                        future: b.pages.first.readAsBytes(),
                        builder: (_, s) => s.hasData
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.memory(s.data!, fit: BoxFit.cover, width: double.infinity))
                            : const SizedBox(),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(b.title),
                    Text('${b.pages.length}ページ',
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
  const Reader({super.key, required this.book});
  final Book book;
  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 280));

  bool _rtl = true; // 右開き
  int _index = 0;
  int _mode = 0; // 0:停止 1:次へ -1:前へ
  double _progress = 0;
  double _acc = 0;

  final Map<int, ui.Image> _cache = {};
  final Set<int> _loading = {};
  Size _cacheSize = Size.zero;

  int get _last => widget.book.pages.length - 1;
  double get _sgn => _rtl ? 1.0 : -1.0; // 「次へ」方向のドラッグ符号

  @override
  void initState() {
    super.initState();
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
    final bytes = await widget.book.pages[i].readAsBytes();
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
  void _settle(double target) {
    final from = _progress;
    final m = _mode;
    _ac.stop();
    _ac.reset();
    final tween = Tween<double>(begin: from, end: target).chain(CurveTween(curve: Curves.easeOut));
    void tick() => setState(() => _progress = tween.evaluate(_ac));
    _ac.addListener(tick);
    _ac.forward().whenComplete(() {
      _ac.removeListener(tick);
      if (!mounted) return;
      setState(() {
        if (m == 1 && target == 1) _index++;
        if (m == -1 && target == 0) _index--;
        _mode = 0;
        _progress = 0;
        _acc = 0;
      });
    });
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

  void _onDragUpdate(DragUpdateDetails d, double w) {
    if (_ac.isAnimating) return;
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
      _progress = (_mode == 1 ? _acc / w : 1 + _acc / w).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    if (_mode == 0) {
      _acc = 0;
      return;
    }
    final v = (d.primaryVelocity ?? 0) * _sgn; // 正:次へ方向
    if (_mode == 1) {
      _settle((_progress > 0.5 || v > 800) ? 1 : 0);
    } else {
      _settle((_progress < 0.5 || v < -800) ? 0 : 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        _sync(size, dpr);

        final curIdx = _mode == -1 ? _index - 1 : _index;
        final nextIdx = _mode == 1 ? _index + 1 : _index;
        final cur = _cache[curIdx];
        final next = _cache[nextIdx];
        final ready = _shader != null && cur != null && next != null;

        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => _onDragUpdate(d, size.width),
              onHorizontalDragEnd: _onDragEnd,
              onTapUp: (d) {
                final x = d.localPosition.dx / size.width;
                if (x < 0.3) _flip(_rtl ? 1 : -1);
                if (x > 0.7) _flip(_rtl ? -1 : 1);
              },
              child: ready
                  ? CustomPaint(
                      painter: _CurlPainter(_shader!, cur, next, _mode == 0 ? 0 : _progress, _rtl))
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
          SafeArea(
            child: Row(children: [
              IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.black54),
                  onPressed: () => Navigator.pop(context)),
              const Spacer(),
              TextButton(
                  onPressed: () => setState(() => _rtl = !_rtl),
                  child: Text(_rtl ? '右開き' : '左開き', style: const TextStyle(color: Colors.black54))),
            ]),
          ),
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
  _CurlPainter(this.shader, this.cur, this.next, this.progress, this.rtl);
  final ui.FragmentShader shader;
  final ui.Image cur, next;
  final double progress;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, progress)
      ..setFloat(3, rtl ? 1.0 : 0.0)
      ..setImageSampler(0, cur)
      ..setImageSampler(1, next);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _CurlPainter old) => true;
}
