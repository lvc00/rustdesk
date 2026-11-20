import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// UU-style touch input layer for the RustDesk Android client.
///
/// Two parts:
///
/// 1. A raw `Listener` state machine that bypasses the Flutter gesture arena,
///    `kPanSlop`, `ScaleGestureRecognizer` and the 200ms debounce.
///      one finger move          -> move the remote cursor immediately
///      one finger tap           -> left click
///      one finger long press    -> right click
///      double tap + move        -> drag (left button held)
///      two finger move          -> wheel scroll
///      two finger pinch         -> zoom (mode locked per gesture)
///      two finger drag zoomed   -> pan the zoomed canvas
///      two finger tap           -> right click
///      three finger tap         -> toggle the tool panel
///
/// 2. A floating overlay mirroring the UU Remote layout: status bar whose
///    position can be moved, a draggable tool ball, a fully customisable
///    shortcut page, a full keyboard page and a view page.
///
/// Flip [useRawTrackpadLayer] to false to fall back to the stock gesture-arena
/// path (the overlay still works).
bool useRawTrackpadLayer = true;

/// Two finger gesture mode. Decided once per gesture so a scroll never turns
/// into a canvas pan half way through — that was the "two finger drags the
/// whole window" bug.
enum _TwoMode { undecided, scroll, pinch, pan }

/// A user editable shortcut.
class UUShortcut {
  String label;
  String key;
  bool ctrl;
  bool alt;
  bool shift;
  bool win;

  UUShortcut(this.label, this.key,
      {this.ctrl = false,
      this.alt = false,
      this.shift = false,
      this.win = false});

  Map<String, dynamic> toJson() => {
        'l': label,
        'k': key,
        'c': ctrl,
        'a': alt,
        's': shift,
        'w': win,
      };

  static UUShortcut fromJson(Map<String, dynamic> m) => UUShortcut(
        (m['l'] ?? '') as String,
        (m['k'] ?? '') as String,
        ctrl: m['c'] == true,
        alt: m['a'] == true,
        shift: m['s'] == true,
        win: m['w'] == true,
      );
}

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
  static const double _scrollStep = 24.0;

  /// Span change ratio that flips a two finger gesture into pinch mode. The
  /// stock logic used ~1.5% (min 1px), so any wobble while scrolling was
  /// mistaken for a pinch, which then left `scale` above 1 and turned every
  /// later two finger move into a canvas pan.
  static const double _pinchRate = 0.06;

  /// Only allow two finger panning when the canvas is clearly zoomed in.
  static const double _panMinScale = 1.12;

  /// How long to observe before locking a two finger gesture as scroll/pan.
  static const int _twoModeLockMs = 70;

  final Map<int, Offset> _pointers = <int, Offset>{};

  Offset _downPos = Offset.zero;
  Offset _lastFocal = Offset.zero;
  Offset _lastTapPos = Offset.zero;
  Offset _globalOffset = Offset.zero;
  int _downTs = 0;
  int _lastTapTs = 0;
  int _twoStartTs = 0;
  int _maxPointers = 0;
  double _moved = 0;
  double _scrollAccum = 0;
  double _lastSpan = 0;
  bool _dragActive = false;
  bool _dragPrimed = false;
  bool _longPressed = false;
  bool _threeFinger = false;
  _TwoMode _twoMode = _TwoMode.undecided;
  Timer? _longPressTimer;

  // ---------------- overlay state ----------------
  bool _panelOpen = false;
  int _tab = 0; // 0 shortcuts, 1 keyboard, 2 view
  int _statusBarPos = 0; // 0 top, 1 bottom, 2 hidden
  Offset? _ballPos;
  final TextEditingController _textController = TextEditingController();
  final FocusNode _imeFocus = FocusNode();
  String _lastText = '';
  bool _imeOpened = false;

  // shortcut editing
  static const String _kShortcutStore = 'uu_shortcuts_v1';
  List<UUShortcut>? _shortcuts;
  int _editing = -1; // -1 none, -2 new, >=0 edit index
  String _editingKey = 'VK_C';
  final TextEditingController _labelController = TextEditingController();

  InputModel get inputModel => widget.ffi.inputModel;
  CanvasModel get canvasModel => widget.ffi.canvasModel;

  @override
  void initState() {
    super.initState();
    _loadShortcuts();
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _textController.dispose();
    _labelController.dispose();
    _imeFocus.dispose();
    _restoreSoftKeyboardFlag();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget gestures = useRawTrackpadLayer
        ? Listener(
            behavior: HitTestBehavior.opaque,
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
              onTap: _closePanel,
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
      _threeFinger = false;
      _twoMode = _TwoMode.undecided;
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
    _twoStartTs = _now;
    _twoMode = _TwoMode.undecided;
    _scrollAccum = 0;
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
    final spanRate = _lastSpan > 1.0 ? (span - _lastSpan).abs() / _lastSpan : 0.0;
    final ratio = _lastSpan > 1.0 ? span / _lastSpan : 1.0;
    _lastSpan = span;
    _moved += deltaDistance;

    if (_twoMode == _TwoMode.undecided) {
      if (spanRate > _pinchRate) {
        _twoMode = _TwoMode.pinch;
        _scrollAccum = 0;
      } else if (_now - _twoStartTs > _twoModeLockMs) {
        // Lock as scroll/pan. Only a clearly zoomed canvas may be panned, so a
        // slightly drifted scale value never steals the scroll gesture.
        _twoMode =
            canvasModel.scale > _panMinScale ? _TwoMode.pan : _TwoMode.scroll;
        if (_twoMode == _TwoMode.pan) _scrollAccum = 0;
      }
    }

    switch (_twoMode) {
      case _TwoMode.pinch:
        // Zoom only. Panning while pinching made the picture look like the
        // window was being dragged around.
        if (ratio > 0.6 && ratio < 1.7) {
          canvasModel.updateScale(ratio, focal + _globalOffset);
        }
        break;
      case _TwoMode.pan:
        canvasModel.panX(dx);
        canvasModel.panY(dy);
        break;
      case _TwoMode.scroll:
        _scrollAccum += dy;
        while (_scrollAccum >= _scrollStep) {
          _scrollAccum -= _scrollStep;
          inputModel.scroll(1);
        }
        while (_scrollAccum <= -_scrollStep) {
          _scrollAccum += _scrollStep;
          inputModel.scroll(-1);
        }
        break;
      case _TwoMode.undecided:
        // Buffer movement, it is flushed as scroll once the mode locks.
        _scrollAccum += dy;
        break;
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
        _togglePanel();
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
    _threeFinger = false;
    _twoMode = _TwoMode.undecided;
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
    im.ctrl = ctrl || oldC;
    im.alt = alt || oldA;
    im.shift = shift || oldS;
    im.command = win || oldW;
    im.inputKey(key);
    im.ctrl = oldC;
    im.alt = oldA;
    im.shift = oldS;
    im.command = oldW;
  }

  void _key(String name) => inputModel.inputKey(name);

  void _runShortcut(UUShortcut s) {
    _combo(s.key, ctrl: s.ctrl, alt: s.alt, shift: s.shift, win: s.win);
    setState(() {});
  }

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

  static const Map<String, String> _shiftMap = {
    '1': '!',
    '2': '@',
    '3': '#',
    '4': r'$',
    '5': '%',
    '6': '^',
    '7': '&',
    '8': '*',
    '9': '(',
    '0': ')',
    '-': '_',
    '=': '+',
    '[': '{',
    ']': '}',
    '\\': '|',
    ';': ':',
    "'": '"',
    ',': '<',
    '.': '>',
    '/': '?',
    '`': '~',
  };

  static const Map<String, String> _charToVk = {
    'a': 'VK_A',
    'b': 'VK_B',
    'c': 'VK_C',
    'd': 'VK_D',
    'e': 'VK_E',
    'f': 'VK_F',
    'g': 'VK_G',
    'h': 'VK_H',
    'i': 'VK_I',
    'j': 'VK_J',
    'k': 'VK_K',
    'l': 'VK_L',
    'm': 'VK_M',
    'n': 'VK_N',
    'o': 'VK_O',
    'p': 'VK_P',
    'q': 'VK_Q',
    'r': 'VK_R',
    's': 'VK_S',
    't': 'VK_T',
    'u': 'VK_U',
    'v': 'VK_V',
    'w': 'VK_W',
    'x': 'VK_X',
    'y': 'VK_Y',
    'z': 'VK_Z',
  };

  String _shifted(String c) {
    if (!inputModel.shift) return c;
    final mapped = _shiftMap[c];
    if (mapped != null) return mapped;
    if (c.length == 1 && c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122) {
      return c.toUpperCase();
    }
    return c;
  }

  /// Sends one visible character. When Ctrl/Alt/Win is held it becomes a real
  /// key combination so remote shortcuts keep working.
  void _char(String c) {
    final im = inputModel;
    if (im.ctrl || im.alt || im.command) {
      final vk = _charToVk[c.toLowerCase()] ??
          (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57 ? 'VK_$c' : null);
      if (vk != null) {
        _combo(vk,
            ctrl: im.ctrl, alt: im.alt, shift: im.shift, win: im.command);
        return;
      }
    }
    bind.sessionInputString(sessionId: widget.ffi.sessionId, value: _shifted(c));
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
  //  System IME
  // =====================================================================

  /// RustDesk calls `enable_soft_keyboard(false)` on startup, which adds
  /// `FLAG_ALT_FOCUSABLE_IM` to the window. While that flag is set Android
  /// refuses to show the IME for *any* text field — that is why tapping the
  /// input box did nothing. Flip it on before requesting focus.
  Future<void> _ensureImeOpen() async {
    if (isAndroid) {
      await widget.ffi.invokeMethod('enable_soft_keyboard', true);
    }
    inputModel.keyboardInputAllowed = true;
    _imeOpened = true;
    if (!mounted) return;
    _imeFocus.requestFocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  void _closeIme() {
    _imeFocus.unfocus();
    _restoreSoftKeyboardFlag();
  }

  void _restoreSoftKeyboardFlag() {
    if (!_imeOpened) return;
    _imeOpened = false;
    if (isAndroid) {
      widget.ffi.invokeMethod('enable_soft_keyboard', false);
    }
  }

  // =====================================================================
  //  Shortcut storage
  // =====================================================================

  static List<UUShortcut> _defaultShortcuts() => [
        UUShortcut('复制', 'VK_C', ctrl: true),
        UUShortcut('粘贴', 'VK_V', ctrl: true),
        UUShortcut('剪切', 'VK_X', ctrl: true),
        UUShortcut('撤销', 'VK_Z', ctrl: true),
        UUShortcut('重做', 'VK_Y', ctrl: true),
        UUShortcut('全选', 'VK_A', ctrl: true),
        UUShortcut('保存', 'VK_S', ctrl: true),
        UUShortcut('查找', 'VK_F', ctrl: true),
        UUShortcut('新建', 'VK_N', ctrl: true),
        UUShortcut('切窗', 'VK_TAB', alt: true),
        UUShortcut('关闭窗口', 'VK_F4', alt: true),
        UUShortcut('显示桌面', 'VK_D', win: true),
        UUShortcut('资源管理器', 'VK_E', win: true),
        UUShortcut('锁屏', 'VK_L', win: true),
        UUShortcut('任务管理器', 'VK_ESCAPE', ctrl: true, shift: true),
        UUShortcut('任务切换', 'VK_TAB', ctrl: true, alt: true),
        UUShortcut('Ctrl+Alt+Del', 'VK_DELETE', ctrl: true, alt: true),
      ];

  void _loadShortcuts() {
    _shortcuts = _defaultShortcuts();
    try {
      final raw = bind.mainGetLocalOption(key: _kShortcutStore);
      if (raw.isNotEmpty) {
        final data = jsonDecode(raw);
        if (data is List) {
          final list = data
              .whereType<Map>()
              .map((e) => UUShortcut.fromJson(e.cast<String, dynamic>()))
              .where((e) => e.key.isNotEmpty)
              .toList();
          if (list.isNotEmpty) _shortcuts = list;
        }
      }
    } catch (_) {
      // keep defaults
    }
  }

  void _saveShortcuts() {
    final list = _shortcuts;
    if (list == null) return;
    try {
      bind.mainSetLocalOption(
        key: _kShortcutStore,
        value: jsonEncode(list.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  // =====================================================================
  //  Overlay widgets
  // =====================================================================

  static const Color _panelBg = Color(0xF21A2030);
  static const Color _barBg = Color(0xB3101622);
  static const Color _btnBg = Color(0xFF2C3648);
  static const Color _accent = Color(0xFF3B82F6);

  void _togglePanel() {
    if (_panelOpen) {
      _closePanel();
    } else {
      setState(() => _panelOpen = true);
      if (_tab == 1) {
        Future.delayed(const Duration(milliseconds: 120), _ensureImeOpen);
      }
    }
  }

  void _closePanel() {
    _closeIme();
    setState(() {
      _panelOpen = false;
      _editing = -1;
    });
  }

  void _openTab(int idx) {
    setState(() {
      _tab = idx;
      _panelOpen = true;
      _editing = -1;
    });
    if (idx == 1) {
      Future.delayed(const Duration(milliseconds: 120), _ensureImeOpen);
    } else {
      _closeIme();
    }
  }

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
      _barIcon(Icons.keyboard, '键盘', () => _openTab(1)),
      _barIcon(Icons.grid_view, '快捷键', () => _openTab(0)),
      _barIcon(Icons.zoom_out_map, '视图', () => _openTab(2)),
      _barIcon(Icons.close, '隐藏状态栏', () {
        _closeIme();
        setState(() => _statusBarPos = 2);
      }),
    ];

    return Positioned(
      top: _statusBarPos == 0 ? 0 : null,
      bottom: _statusBarPos == 1 ? 0 : null,
      left: 0,
      right: 0,
      // `Listener` swallowing instead of a tap handler: it stops taps on the
      // empty part of the bar from reaching the remote desktop without
      // competing with the icon detectors in the gesture arena.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {},
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
        onTap: _togglePanel,
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
              BoxShadow(
                  color: Colors.black45, blurRadius: 6, offset: Offset(0, 2))
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
    final width = size.width * 0.9 < 340 ? size.width * 0.9 : 340.0;
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Positioned(
      top: 8,
      bottom: 8 + insets,
      right: 10,
      width: width,
      // Opaque `Listener`: taps inside the panel never fall through to the
      // remote desktop, and it does not steal taps from the TextField.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {},
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
                        onTap: _closePanel,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close,
                              size: 16, color: Colors.white70),
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
                          ? (_editing == -1 ? _shortcutPage() : _shortcutEditor())
                          : (_tab == 1 ? _keyboardPage() : _viewPage()),
                    ),
                  ),
                ],
              ),
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
        onTap: () => _openTab(idx),
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

  Widget _keyButton(String label, VoidCallback onTap,
      {bool active = false,
      double width = 70,
      double height = 32,
      VoidCallback? onLongPress}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? _accent : _btnBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Colors.white,
              fontSize: height > 30 ? 11 : 10,
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

  // =====================================================================
  //  Shortcut page (customisable)
  // =====================================================================

  Widget _shortcutPage() {
    final list = _shortcuts ?? <UUShortcut>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle('修饰键锁定（锁定后下方按键自动带上）'),
        _wrap([
          _keyButton('Ctrl', () => _toggleModifier(0), active: inputModel.ctrl),
          _keyButton('Alt', () => _toggleModifier(1), active: inputModel.alt),
          _keyButton('Shift', () => _toggleModifier(2),
              active: inputModel.shift),
          _keyButton('Win', () => _toggleModifier(3),
              active: inputModel.command),
        ]),
        Row(
          children: [
            const Expanded(child: SizedBox()),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _startEdit(-2),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Text(
                  '+ 自定义快捷键',
                  style: TextStyle(color: Color(0xFF4ADE80), fontSize: 11),
                ),
              ),
            ),
          ],
        ),
        _sectionTitle('我的快捷键（长按可编辑 / 删除）'),
        _wrap([
          for (int i = 0; i < list.length; i++)
            _keyButton(
              list[i].label.isEmpty ? _shortcutText(list[i]) : list[i].label,
              () => _runShortcut(list[i]),
              onLongPress: () => _startEdit(i),
              width: 86,
            ),
        ]),
        _sectionTitle('功能键（随锁定修饰键变化）'),
        _wrap([
          _keyButton('Esc', () => _key('VK_ESCAPE'), width: 56),
          _keyButton('Tab', () => _key('VK_TAB'), width: 56),
          _keyButton('Enter', () => _key('VK_ENTER'), width: 62),
          _keyButton('退格', () => _key('VK_BACK'), width: 56),
          _keyButton('Del', () => _key('VK_DELETE'), width: 52),
          _keyButton('Home', () => _key('VK_HOME'), width: 58),
          _keyButton('End', () => _key('VK_END'), width: 52),
          _keyButton('PgUp', () => _key('VK_PRIOR'), width: 58),
          _keyButton('PgDn', () => _key('VK_NEXT'), width: 58),
          _keyButton('截图', () => _key('VK_SNAPSHOT'), width: 56),
          _keyButton('↑', () => _key('VK_UP'), width: 42),
          _keyButton('↓', () => _key('VK_DOWN'), width: 42),
          _keyButton('←', () => _key('VK_LEFT'), width: 42),
          _keyButton('→', () => _key('VK_RIGHT'), width: 42),
          for (int i = 1; i <= 12; i++)
            _keyButton('F$i', () => _key('VK_F$i'), width: 42),
        ]),
        const SizedBox(height: 6),
        const Text(
          '提示：长按任意快捷键可改名、改组合；三指轻点画面可随时呼出/收起本面板。',
          style: TextStyle(color: Colors.white38, fontSize: 10),
        ),
      ],
    );
  }

  static String _keyLabel(String key) {
    if (!key.startsWith('VK_')) return key;
    final s = key.substring(3);
    if (s.length == 1) return s;
    const m = {
      'ENTER': 'Enter',
      'ESCAPE': 'Esc',
      'TAB': 'Tab',
      'SPACE': 'Space',
      'BACK': 'Back',
      'DELETE': 'Del',
      'INSERT': 'Ins',
      'PRIOR': 'PgUp',
      'NEXT': 'PgDn',
      'CAPITAL': 'Caps',
      'UP': '↑',
      'DOWN': '↓',
      'LEFT': '←',
      'RIGHT': '→',
      'MINUS': '-',
      'PLUS': '=',
      'COMMA': ',',
      'SEMICOLON': ';',
      'SLASH': '/',
      'QUOTE': "'",
      'LBRACKET': '[',
      'RBRACKET': ']',
      'BACKSLASH': '\\',
    };
    return m[s] ?? s;
  }

  static String _shortcutText(UUShortcut s) {
    final b = StringBuffer();
    if (s.ctrl) b.write('Ctrl+');
    if (s.alt) b.write('Alt+');
    if (s.shift) b.write('Shift+');
    if (s.win) b.write('Win+');
    b.write(_keyLabel(s.key));
    return b.toString();
  }

  static List<String> get _editableKeys => [
        for (final c in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) 'VK_$c',
        for (int i = 0; i <= 9; i++) 'VK_$i',
        for (int i = 1; i <= 12; i++) 'VK_F$i',
        'VK_TAB',
        'VK_ENTER',
        'VK_ESCAPE',
        'VK_SPACE',
        'VK_BACK',
        'VK_DELETE',
        'VK_INSERT',
        'VK_HOME',
        'VK_END',
        'VK_PRIOR',
        'VK_NEXT',
        'VK_UP',
        'VK_DOWN',
        'VK_LEFT',
        'VK_RIGHT',
        'VK_MINUS',
        'VK_PLUS',
        'VK_COMMA',
        'VK_SEMICOLON',
        'VK_SLASH',
        'VK_QUOTE',
        'VK_LBRACKET',
        'VK_RBRACKET',
        'VK_BACKSLASH',
      ];

  void _startEdit(int idx) {
    final list = _shortcuts ?? <UUShortcut>[];
    setState(() {
      _editing = idx;
      if (idx >= 0 && idx < list.length) {
        _labelController.text = list[idx].label;
        _editingKey = list[idx].key;
      } else {
        _labelController.text = '';
        _editingKey = 'VK_C';
      }
    });
  }

  /// Returns the shortcut being edited, creating a scratch entry for "new" so
  /// the modifier switches have something to mutate.
  UUShortcut _editTarget() {
    final list = _shortcuts ??= <UUShortcut>[];
    if (_editing == -2) {
      final s = UUShortcut('', _editingKey);
      list.add(s);
      _editing = list.length - 1;
      return s;
    }
    if (_editing >= 0 && _editing < list.length) {
      list[_editing].key = _editingKey;
      return list[_editing];
    }
    final s = UUShortcut('', _editingKey);
    list.add(s);
    _editing = list.length - 1;
    return s;
  }

  Widget _shortcutEditor() {
    final isNew = _editing == -2;
    final list = _shortcuts ?? <UUShortcut>[];
    final cur =
        (!isNew && _editing >= 0 && _editing < list.length) ? list[_editing] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle(isNew ? '新增快捷键' : '编辑快捷键'),
        TextField(
          controller: _labelController,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: _btnBg,
            hintText: '名称，例如：复制',
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        _sectionTitle('修饰键'),
        _wrap([
          _modSwitch('Ctrl', cur?.ctrl ?? false, () {
            setState(() => _editTarget().ctrl = !(cur?.ctrl ?? false));
          }),
          _modSwitch('Alt', cur?.alt ?? false, () {
            setState(() => _editTarget().alt = !(cur?.alt ?? false));
          }),
          _modSwitch('Shift', cur?.shift ?? false, () {
            setState(() => _editTarget().shift = !(cur?.shift ?? false));
          }),
          _modSwitch('Win', cur?.win ?? false, () {
            setState(() => _editTarget().win = !(cur?.win ?? false));
          }),
        ]),
        _sectionTitle('主键（当前：${_keyLabel(_editingKey)}）'),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final k in _editableKeys)
              _keyButton(
                _keyLabel(k),
                () => setState(() => _editingKey = k),
                active: _editingKey == k,
                width: 32,
                height: 26,
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _keyButton('保存', _commitEdit, active: true, width: 64),
            const SizedBox(width: 6),
            _keyButton('取消', () => setState(() => _editing = -1), width: 56),
            const Spacer(),
            if (!isNew)
              _keyButton('删除', () {
                final l = _shortcuts;
                if (l != null && _editing >= 0 && _editing < l.length) {
                  l.removeAt(_editing);
                  _saveShortcuts();
                }
                setState(() => _editing = -1);
              }, width: 56),
          ],
        ),
      ],
    );
  }

  Widget _modSwitch(String label, bool on, VoidCallback onTap) {
    return _keyButton(label, onTap, active: on, width: 60, height: 30);
  }

  void _commitEdit() {
    final list = _shortcuts ??= <UUShortcut>[];
    final label = _labelController.text.trim();
    if (_editing == -2) {
      list.add(UUShortcut(label, _editingKey));
      _editing = list.length - 1;
    } else if (_editing >= 0 && _editing < list.length) {
      list[_editing].label = label;
      list[_editing].key = _editingKey;
    }
    _saveShortcuts();
    setState(() => _editing = -1);
  }

  // =====================================================================
  //  Keyboard page (all keys)
  // =====================================================================

  Widget _keyboardPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionTitle('系统输入法（中文 / 表情 / 手写）'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                focusNode: _imeFocus,
                maxLines: 2,
                minLines: 1,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                onTap: _ensureImeOpen,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: _btnBg,
                  hintText: '点一下唤起输入法，输入内容实时发送',
                  hintStyle:
                      const TextStyle(color: Colors.white38, fontSize: 11),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: _onTextChanged,
              ),
            ),
            const SizedBox(width: 6),
            _keyButton('⌨', _ensureImeOpen, width: 40, height: 40),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _keyButton('回车', _sendEnter, width: 52, height: 28),
            const SizedBox(width: 4),
            _keyButton('退格', () => _key('VK_BACK'), width: 52, height: 28),
            const SizedBox(width: 4),
            _keyButton('清空', () {
              _textController.clear();
              _lastText = '';
            }, width: 52, height: 28),
            const Spacer(),
            _keyButton('收起键盘', _closeIme, width: 70, height: 28),
          ],
        ),
        _sectionTitle('完整键盘（含符号 / 功能键）'),
        _kbRow(['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']),
        _kbRow(['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p']),
        _kbRow(['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l']),
        _kbRow(['z', 'x', 'c', 'v', 'b', 'n', 'm']),
        _kbRow(['-', '=', '[', ']', '\\', ';', "'", ',', '.', '/']),
        _kbRow(['`', '~', '!', '@', '#', r'$', '%', '^', '&', '*']),
        _kbRow(['(', ')', '_', '+', '{', '}', '|', ':', '"', '<', '>', '?']),
        _kbRow([], extra: [
          _keyButton('Tab', () => _key('VK_TAB'), width: 44, height: 28),
          _keyButton('Esc', () => _key('VK_ESCAPE'), width: 44, height: 28),
          _keyButton('Back', () => _key('VK_BACK'), width: 46, height: 28),
          _keyButton('Enter', () => _key('VK_ENTER'), width: 50, height: 28),
          _keyButton('Space', () => _key('VK_SPACE'), width: 70, height: 28),
          _keyButton('Del', () => _key('VK_DELETE'), width: 42, height: 28),
        ]),
        _kbRow([], extra: [
          _keyButton('Ins', () => _key('VK_INSERT'), width: 40, height: 28),
          _keyButton('Home', () => _key('VK_HOME'), width: 46, height: 28),
          _keyButton('End', () => _key('VK_END'), width: 40, height: 28),
          _keyButton('PgUp', () => _key('VK_PRIOR'), width: 46, height: 28),
          _keyButton('PgDn', () => _key('VK_NEXT'), width: 46, height: 28),
          _keyButton('截图', () => _key('VK_SNAPSHOT'), width: 46, height: 28),
        ]),
        _kbRow([], extra: [
          _keyButton('Ctrl', () => _toggleModifier(0),
              active: inputModel.ctrl, width: 46, height: 28),
          _keyButton('Alt', () => _toggleModifier(1),
              active: inputModel.alt, width: 42, height: 28),
          _keyButton('Shift', () => _toggleModifier(2),
              active: inputModel.shift, width: 48, height: 28),
          _keyButton('Win', () => _toggleModifier(3),
              active: inputModel.command, width: 42, height: 28),
          _keyButton('Caps', () => _key('VK_CAPITAL'), width: 44, height: 28),
          _keyButton('↑', () => _key('VK_UP'), width: 34, height: 28),
          _keyButton('↓', () => _key('VK_DOWN'), width: 34, height: 28),
          _keyButton('←', () => _key('VK_LEFT'), width: 34, height: 28),
          _keyButton('→', () => _key('VK_RIGHT'), width: 34, height: 28),
        ]),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (int i = 1; i <= 12; i++)
              _keyButton('F$i', () => _key('VK_F$i'), width: 34, height: 26),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Shift / Ctrl / Alt / Win 为锁定开关：点亮后再按字母或符号即为组合键。',
          style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.5),
        ),
      ],
    );
  }

  Widget _kbRow(List<String> chars, {List<Widget>? extra}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 3,
        runSpacing: 3,
        children: [
          for (final c in chars) _keyButton(c, () => _char(c), width: 27, height: 30),
          if (extra != null) ...extra,
        ],
      ),
    );
  }

  // =====================================================================
  //  View page
  // =====================================================================

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
            setState(() =>
                _ballPos = Offset(size.width - 62, size.height * 0.5));
          }),
          _keyButton(
            useRawTrackpadLayer ? '手势:UU' : '手势:原生',
            () => setState(() => useRawTrackpadLayer = !useRawTrackpadLayer),
            active: useRawTrackpadLayer,
          ),
          _keyButton('恢复默认快捷键', () {
            setState(() => _shortcuts = _defaultShortcuts());
            _saveShortcuts();
          }, width: 108),
        ]),
        const SizedBox(height: 8),
        const Text(
          '手势对照：\n'
          '单指滑动 = 移动光标（零延迟）｜单指轻点 = 左键\n'
          '单指长按 = 右键｜双击后滑动 = 左键拖拽\n'
          '双指上下 = 滚轮｜双指捏合 = 缩放屏幕\n'
          '放大后可双指平移画面｜双指轻点 = 右键\n'
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
