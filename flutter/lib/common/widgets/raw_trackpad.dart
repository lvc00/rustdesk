import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// UU-style touch input layer for the RustDesk Android client.
///
/// There are two parts:
///
/// 1. A raw `Listener` state machine that bypasses the Flutter gesture arena,
///    `kPanSlop`, `ScaleGestureRecognizer` and the 200ms debounce. This makes
///    one-finger cursor movement start on the very first frame.
///      one finger move    -> move the remote cursor immediately
///      one finger tap     -> left click
///      one finger long press -> right click
///      double tap + move  -> drag (left button held)
///      two finger move    -> wheel scroll
///      two finger pinch   -> zoom the remote screen (new)
///      two finger drag after zoom -> pan the zoomed canvas (new)
///      two finger tap     -> right click
///      three finger tap   -> toggle the UU-style tool panel (new)
///
/// 2. A floating overlay that mirrors the UU Remote layout: a status bar whose
///    position can be moved, a draggable tool ball, a keyboard / shortcut /
///    view panel. All of it is rendered inside this widget's `Stack`, so no
///    upstream page file has to be touched.
///
/// Flip [useRawTrackpadLayer] to false to fall back to the stock gesture-arena
/// path (the overlay still works).
bool useRawTrackpadLayer = true;

class RawTrackpadLayer extends StatefulWidget {
  final Widget child;
  final FFI ffi;
  final bool handleTouch;
  final Map<Type, GestureRecognizerFactory> nativeGestures;

  RawTrackpadLayer({
    required this.child,
    required this.ffi,
    required this.handleTouch,
    required this.nativeGestures,
  });

  @override
  State<RawTrackpadLayer> createState() => _RawTrackpadLayerState();
}

class _RawTrackpadLayerState extends State<RawTrackpadLayer> {
  // A tap is decided on pointer up by distance and duration, not by the arena.
  static const double _tapSlop = 14.0;
  static const int _tapMaxMs = 320;
  static const int _doubleTapMs = 300;
  static const int _longPressMs = 500;
  static const double _dragSlop = 4.0;
  static const double _scrollStep = 12.0;

  final Map<int, Offset> _pointers = <int, Offset>{};

  Offset _downPos = Offset.zero;
  Offset _lastFocal = Offset.zero;
  Offset _lastTapPos = Offset.zero;
  Offset _globalOffset = Offset.zero;
  int _downTs = 0;
  int _lastTapTs = 0;
  int _maxPointers = 0;
  double _moved = 0;
  double _scrollAccum = 0;
  double _lastSpan = 0;
  bool _dragActive = false;
  bool _dragPrimed = false;
  bool _longPressed = false;
  bool _pinching = false;
  bool _threeFinger = false;
  Timer? _longPressTimer;

  // ---------------- overlay state ----------------
  bool _panelOpen = false;
  int _tab = 0; // 0 shortcuts, 1 keyboard, 2 view
  int _statusBarPos = 0; // 0 top, 1 bottom, 2 hidden
  Offset? _ballPos;
  final TextEditingController _textController = TextEditingController();
  String _lastText = '';

  InputModel get inputModel => widget.ffi.inputModel;
  CanvasModel get canvasModel => widget.ffi.canvasModel;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget gestures = useRawTrackpadLayer
        ? Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onUp,
            onPointerCancel: _onCancel,
            child: widget.child,
          )
        : RawGestureDetector(
            child: widget.child,
            gestures: widget.nativeGestures,
          );

    final size = MediaQuery.of(context).size;
    _ballPos ??= Offset(size.width - 62, size.height * 0.5);

    return Stack(
      children: [
        Positioned.fill(child: gestures),
        if (_panelOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _panelOpen = false),
            ),
          ),
        if (_statusBarPos != 2) _buildStatusBar(context),
        if (_panelOpen) _buildPanel(context, size),
        _buildBall(),
      ],
    );
  }

  // =====================================================================
  //  Gesture state machine
  // =====================================================================

  int get _now => DateTime.now().millisecondsSinceEpoch;

  Offset _focalPoint() {
    if (_pointers.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final p in _pointers.values) {
      sum += p;
    }
    return sum / _pointers.length.toDouble();
  }

  double _span() {
    if (_pointers.length < 2) return 0;
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _globalOffset = e.position - e.localPosition;

    if (_pointers.length >= 3) {
      _threeFinger = true;
      _maxPointers = _pointers.length;
      _lastFocal = _focalPoint();
      _lastSpan = _span();
      _longPressTimer?.cancel();
      return;
    }

    if (_pointers.length == 1) {
      _downPos = e.localPosition;
      _downTs = _now;
      _lastFocal = e.localPosition;
      _moved = 0;
      _scrollAccum = 0;
      _maxPointers = 1;
      _dragActive = false;
      _longPressed = false;
      _pinching = false;
      _threeFinger = false;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
        if (_pointers.length == 1 &&
            _moved < _tapSlop &&
            !_dragActive &&
            !_longPressed) {
          _longPressed = true;
          inputModel.tap(MouseButtons.right);
        }
      });
      return;
    }

    if (_pointers.length > _maxPointers) {
      _maxPointers = _pointers.length;
    }
    _longPressTimer?.cancel();
    _lastFocal = _focalPoint();
    _lastSpan = _span();
    _pinching = false;
    if (_dragActive) {
      _dragActive = false;
      _dragPrimed = false;
      inputModel.tapUp(MouseButtons.left);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    _globalOffset = e.position - e.localPosition;

    if (_threeFinger) {
      _moved += e.delta.distance;
      return;
    }

    if (_pointers.length >= 2) {
      if (_moved > _tapSlop) _longPressTimer?.cancel();
      _moveTwoFingers(e.delta.distance);
      return;
    }

    // One finger: move the cursor right away, zero slop.
    _moved += e.delta.distance;
    if (_moved > _tapSlop) _longPressTimer?.cancel();
    final pos = e.localPosition;
    if (_dragPrimed && !_dragActive && _moved > _dragSlop) {
      _dragActive = true;
      _dragPrimed = false;
      inputModel.tapDown(MouseButtons.left);
    }
    if (widget.ffi.cursorModel.shouldBlock(pos.dx, pos.dy)) return;
    if (inputModel.relativeMouseMode.value) {
      inputModel.sendMobileRelativeMouseMove(e.delta.dx, e.delta.dy);
    } else {
      widget.ffi.cursorModel.updatePan(e.delta, pos, widget.handleTouch);
    }
    _lastFocal = pos;
  }

  void _moveTwoFingers(double deltaDistance) {
    final focal = _focalPoint();
    final dx = focal.dx - _lastFocal.dx;
    final dy = focal.dy - _lastFocal.dy;
    _lastFocal = focal;

    final span = _span();
    double threshold = _lastSpan * 0.015;
    if (threshold < 1.0) threshold = 1.0;
    final spanChanged =
        _lastSpan > 0 && (span - _lastSpan).abs() > threshold;
    final ratio = _lastSpan > 0 ? span / _lastSpan : 1.0;
    _lastSpan = span;
    _moved += deltaDistance;

    if (spanChanged) {
      _pinching = true;
    }

    if (_pinching) {
      // Pinch to zoom. focalPoint is expected in global coordinates by
      // CanvasModel.updateScale (same as ScaleGestureRecognizer.focalPoint).
      if (ratio > 0.5 && ratio < 2.0) {
        canvasModel.updateScale(ratio, focal + _globalOffset);
      }
      canvasModel.panX(dx);
      canvasModel.panY(dy);
      _scrollAccum = 0;
      return;
    }

    if (canvasModel.scale > 1.01) {
      // Already zoomed in: two-finger drag pans the canvas.
      canvasModel.panX(dx);
      canvasModel.panY(dy);
      _scrollAccum = 0;
      return;
    }

    // Not zoomed: two-finger vertical move is a wheel scroll.
    _scrollAccum += dy;
    while (_scrollAccum >= _scrollStep) {
      _scrollAccum -= _scrollStep;
      inputModel.scroll(1);
    }
    while (_scrollAccum <= -_scrollStep) {
      _scrollAccum += _scrollStep;
      inputModel.scroll(-1);
    }
  }

  void _onUp(PointerUpEvent e) {
    final held = _now - _downTs;
    final isTap = _moved <= _tapSlop && held <= _tapMaxMs;
    _pointers.remove(e.pointer);
    _longPressTimer?.cancel();

    if (_threeFinger) {
      if (_pointers.isNotEmpty) return;
      if (isTap || held <= _tapMaxMs + 250) {
        setState(() => _panelOpen = !_panelOpen);
      }
      _resetGesture();
      return;
    }

    if (_pointers.isNotEmpty) return;

    if (_dragActive) {
      inputModel.tapUp(MouseButtons.left);
    } else if (_longPressed) {
      // right click already sent by the long-press timer
    } else if (isTap) {
      if (_maxPointers >= 2) {
        inputModel.tap(MouseButtons.right);
        _dragPrimed = false;
        _lastTapTs = 0;
      } else if (_now - _lastTapTs <= _doubleTapMs &&
          (_lastTapPos - _downPos).distance < 40) {
        _dragPrimed = true;
        _lastTapTs = 0;
      } else {
        inputModel.tap(MouseButtons.left);
        _lastTapTs = _now;
        _lastTapPos = _downPos;
        _dragPrimed = false;
      }
    } else {
      _dragPrimed = false;
    }
    _resetGesture();
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    _longPressTimer?.cancel();
    if (_pointers.isNotEmpty) return;
    if (_dragActive) {
      inputModel.tapUp(MouseButtons.left);
    }
    _resetGesture();
  }

  void _resetGesture() {
    _dragActive = false;
    _dragPrimed = false;
    _longPressed = false;
    _pinching = false;
    _threeFinger = false;
    _maxPointers = 0;
    _moved = 0;
    _scrollAccum = 0;
    _lastSpan = 0;
    _lastFocal = Offset.zero;
  }

  // =====================================================================
  //  Key helpers
  // =====================================================================

  void _combo(String key,
      {bool ctrl = false,
      bool alt = false,
      bool shift = false,
      bool win = false}) {
    final im = inputModel;
    final oldC = im.ctrl;
    final oldA = im.alt;
    final oldS = im.shift;
    final oldW = im.command;
    im.ctrl = ctrl;
    im.alt = alt;
    im.shift = shift;
    im.command = win;
    im.inputKey(key);
    im.ctrl = oldC;
    im.alt = oldA;
    im.shift = oldS;
    im.command = oldW;
  }

  void _key(String name) => inputModel.inputKey(name);

  void _toggleModifier(int idx) {
    setState(() {
      switch (idx) {
        case 0:
          inputModel.ctrl = !inputModel.ctrl;
          break;
        case 1:
          inputModel.alt = !inputModel.alt;
          break;
        case 2:
          inputModel.shift = !inputModel.shift;
          break;
        case 3:
          inputModel.command = !inputModel.command;
          break;
      }
    });
  }

  void _onTextChanged(String v) {
    if (v == _lastText) return;
    // Wait until the IME finishes composing (Chinese pinyin candidates, etc.)
    // so we never send half-composed text to the remote side.
    if (_textController.value.isComposingRangeValid) return;
    if (v.length > _lastText.length && v.startsWith(_lastText)) {
      final delta = v.substring(_lastText.length);
      if (delta.isNotEmpty) {
        bind.sessionInputString(sessionId: widget.ffi.sessionId, value: delta);
      }
    } else if (v.length < _lastText.length) {
      for (int i = 0; i < _lastText.length - v.length; i++) {
        inputModel.inputKey('VK_BACK');
      }
    } else {
      if (v.isNotEmpty) {
        bind.sessionInputString(sessionId: widget.ffi.sessionId, value: v);
      }
    }
    _lastText = v;
  }

  void _sendEnter() {
    _key('VK_ENTER');
  }

  // =====================================================================
  //  Overlay widgets
  // =====================================================================

  static const Color _panelBg = Color(0xE61A2030);
  static const Color _barBg = Color(0xB3101622);
  static const Color _btnBg = Color(0xFF2C3648);
  static const Color _accent = Color(0xFF3B82F6);

  Widget _buildStatusBar(BuildContext context) {
    final items = <Widget>[
      Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: Color(0xFF4ADE80),
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 6),
      const Text(
        'UU 手势 · 已连接',
        style: TextStyle(color: Colors.white, fontSize: 11),
      ),
      const SizedBox(width: 10),
      AnimatedBuilder(
        animation: canvasModel,
        builder: (_, __) => Text(
          '${(canvasModel.scale * 100).round()}%',
          style: const TextStyle(color: Color(0xFF8AB4F8), fontSize: 11),
        ),
      ),
      const Spacer(),
      _barIcon(Icons.keyboard, '键盘', () {
        setState(() {
          _tab = 1;
          _panelOpen = true;
        });
      }),
      _barIcon(Icons.grid_view, '快捷键', () {
        setState(() {
          _tab = 0;
          _panelOpen = true;
        });
      }),
      _barIcon(Icons.zoom_out_map, '视图', () {
        setState(() {
          _tab = 2;
          _panelOpen = true;
        });
      }),
      _barIcon(Icons.close, '隐藏状态栏', () {
        setState(() => _statusBarPos = 2);
      }),
    ];

    return Positioned(
      top: _statusBarPos == 0 ? 0 : null,
      bottom: _statusBarPos == 1 ? 0 : null,
      left: 0,
      right: 0,
      // Opaque tap shield: without it, taps on empty parts of the bar would
      // fall through to the Listener below and click the remote desktop.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Container(
          height: 30,
          color: _barBg,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: items),
        ),
      ),
    );
  }

  Widget _barIcon(IconData icon, String tip, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(icon, size: 17, color: Colors.white70),
      ),
    );
  }

  Widget _buildBall() {
    final p = _ballPos ?? const Offset(300, 300);
    return Positioned(
      left: p.dx,
      top: p.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _panelOpen = !_panelOpen),
        onPanUpdate: (d) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _ballPos = Offset(
              (p.dx + d.delta.dx).clamp(0.0, size.width - 44).toDouble(),
              (p.dy + d.delta.dy).clamp(0.0, size.height - 44).toDouble(),
            );
          });
        },
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _panelOpen ? _accent : _panelBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: const [
              BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2))
            ],
          ),
          child: Icon(
            _panelOpen ? Icons.close : Icons.tune,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, Size size) {
    return Positioned(
      top: 8,
      bottom: 8,
      right: 12,
      width: 320,
      child: Material(
        color: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            color: _panelBg,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'UU 工具箱',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _panelOpen = false),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close, size: 16, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _tabButton('快捷键', 0),
                    _tabButton('键盘', 1),
                    _tabButton('视图', 2),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: _tab == 0
                        ? _shortcutPage()
                        : (_tab == 1 ? _keyboardPage() : _viewPage()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton(String label, int idx) {
    final active = _tab == idx;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _tab = idx),
        child: Container(
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? _accent : _btnBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
                color: active ? Colors.white : Colors.white70, fontSize: 12),
          ),
        ),
      ),
    );
  }

  Widget _keyButton(String label, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 70,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? _accent : _btnBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: active ? Colors.white : Colors.white,
              fontSize: 11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal),
        ),
      ),
    );
  }

  Widget _wrap(List<Widget> children) {
    return Wrap(spacing: 6, runSpacing: 6, children: children);
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        t,
        style: const TextStyle(color: Color(0xFF8AB4F8), fontSize: 11),
      ),
    );
  }

  Widget _shortcutPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle('修饰键锁定（锁定后下方功能键自动带上）'),
        _wrap([
          _keyButton('Ctrl', () => _toggleModifier(0),
              active: inputModel.ctrl),
          _keyButton('Alt', () => _toggleModifier(1), active: inputModel.alt),
          _keyButton('Shift', () => _toggleModifier(2),
              active: inputModel.shift),
          _keyButton('Win', () => _toggleModifier(3),
              active: inputModel.command),
        ]),
        _sectionTitle('常用组合键'),
        _wrap([
          _keyButton('复制 C', () => _combo('VK_C', ctrl: true)),
          _keyButton('粘贴 V', () => _combo('VK_V', ctrl: true)),
          _keyButton('剪切 X', () => _combo('VK_X', ctrl: true)),
          _keyButton('撤销 Z', () => _combo('VK_Z', ctrl: true)),
          _keyButton('全选 A', () => _combo('VK_A', ctrl: true)),
          _keyButton('保存 S', () => _combo('VK_S', ctrl: true)),
          _keyButton('查找 F', () => _combo('VK_F', ctrl: true)),
          _keyButton('新建 N', () => _combo('VK_N', ctrl: true)),
          _keyButton('切窗 Tab', () => _combo('VK_TAB', alt: true)),
          _keyButton('关窗 F4', () => _combo('VK_F4', alt: true)),
          _keyButton('桌面 D', () => _combo('VK_D', win: true)),
          _keyButton('资源 E', () => _combo('VK_E', win: true)),
          _keyButton('锁屏 L', () => _combo('VK_L', win: true)),
          _keyButton('任务管理器',
              () => _combo('VK_ESCAPE', ctrl: true, shift: true)),
          _keyButton('CtrlAltDel',
              () => _combo('VK_DELETE', ctrl: true, alt: true)),
          _keyButton('Win', () => _key('Meta')),
        ]),
        _sectionTitle('功能键（随锁定修饰键变化）'),
        _wrap([
          _keyButton('Esc', () => _key('VK_ESCAPE')),
          _keyButton('Tab', () => _key('VK_TAB')),
          _keyButton('Enter', () => _key('VK_ENTER')),
          _keyButton('退格', () => _key('VK_BACK')),
          _keyButton('Del', () => _key('VK_DELETE')),
          _keyButton('Home', () => _key('VK_HOME')),
          _keyButton('End', () => _key('VK_END')),
          _keyButton('PgUp', () => _key('VK_PRIOR')),
          _keyButton('PgDn', () => _key('VK_NEXT')),
          _keyButton('截图', () => _key('VK_SNAPSHOT')),
          _keyButton('↑', () => _key('VK_UP')),
          _keyButton('↓', () => _key('VK_DOWN')),
          _keyButton('←', () => _key('VK_LEFT')),
          _keyButton('→', () => _key('VK_RIGHT')),
          for (int i = 1; i <= 12; i++)
            _keyButton('F$i', () => _key('VK_F$i')),
        ]),
        const SizedBox(height: 6),
        const Text(
          '提示：三指轻点画面可随时呼出/收起本面板；单指长按为右键。',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }

  Widget _keyboardPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle('文字输入（支持中文，边打边发）'),
        TextField(
          controller: _textController,
          autofocus: true,
          maxLines: 3,
          minLines: 2,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: _btnBg,
            hintText: '点这里唤起输入法，输入内容会实时发送到远端',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: _onTextChanged,
        ),
        const SizedBox(height: 8),
        _wrap([
          _keyButton('回车', _sendEnter),
          _keyButton('退格', () => _key('VK_BACK')),
          _keyButton('Esc', () => _key('VK_ESCAPE')),
          _keyButton('Tab', () => _key('VK_TAB')),
          _keyButton('Ctrl+回车', () => _combo('VK_ENTER', ctrl: true)),
          _keyButton('清空', () {
            _textController.clear();
            _lastText = '';
          }),
        ]),
        const SizedBox(height: 8),
        const Text(
          '键盘方式：点击输入框唤起系统输入法，中文整句可直接送入被控端；\n'
          '也可用上方「快捷键」页的修饰键 + 功能键发送组合键。',
          style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.5),
        ),
      ],
    );
  }

  Widget _viewPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle('画面缩放（也可双指捏合）'),
        _wrap([
          _keyButton('放大 +', () => _zoom(1.25)),
          _keyButton('缩小 −', () => _zoom(0.8)),
          _keyButton('复位 100%', () {
            _zoom(1.0 / canvasModel.scale);
            canvasModel.resetOffset();
            setState(() {});
          }),
        ]),
        _sectionTitle('状态栏位置'),
        _wrap([
          _keyButton('顶部', () => setState(() => _statusBarPos = 0),
              active: _statusBarPos == 0),
          _keyButton('底部', () => setState(() => _statusBarPos = 1),
              active: _statusBarPos == 1),
          _keyButton('隐藏', () => setState(() => _statusBarPos = 2),
              active: _statusBarPos == 2),
        ]),
        _sectionTitle('其它'),
        _wrap([
          _keyButton('球复位', () {
            final size = MediaQuery.of(context).size;
            setState(() => _ballPos = Offset(size.width - 62, size.height * 0.5));
          }),
          _keyButton(
            useRawTrackpadLayer ? '手势:UU' : '手势:原生',
            () => setState(() => useRawTrackpadLayer = !useRawTrackpadLayer),
            active: useRawTrackpadLayer,
          ),
        ]),
        const SizedBox(height: 8),
        const Text(
          '手势对照：\n'
          '单指滑动 = 移动光标（零延迟）｜单指轻点 = 左键\n'
          '单指长按 = 右键｜双击后滑动 = 左键拖拽\n'
          '双指上下 = 滚轮｜双指捏合 = 缩放屏幕\n'
          '缩放后双指拖动 = 平移画面｜双指轻点 = 右键\n'
          '三指轻点 = 呼出/收起工具箱',
          style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.6),
        ),
      ],
    );
  }

  void _zoom(double factor) {
    final size = MediaQuery.of(context).size;
    canvasModel.updateScale(factor, Offset(size.width / 2, size.height / 2));
  }
}
