import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// UU-style trackpad input layer for touch devices.
///
/// Why this exists: RustDesk drives single finger movement through
/// `ScaleGestureRecognizer` inside the Flutter gesture arena, so the cursor
/// only starts moving after the pointer travels beyond `kPanSlop` and after the
/// recognizer wins the arena. That slop plus the 200ms debounce in
/// `CustomTouchGestureRecognizer` is what makes the Android client feel sticky.
///
/// This layer listens to raw pointer events (no arena, no slop, no timer):
///   one finger move   -> move remote cursor immediately
///   one finger tap    -> left click
///   double tap + move -> drag (left button down, hold)
///   two finger move   -> wheel scroll
///   two finger tap    -> right click
///
/// Flip [useRawTrackpadLayer] to false to fall back to the original
/// gesture-arena path without touching any other code.
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
  static const double _dragSlop = 4.0;
  static const double _scrollStep = 12.0;

  final Map<int, Offset> _pointers = <int, Offset>{};

  Offset _downPos = Offset.zero;
  Offset _lastFocal = Offset.zero;
  Offset _lastTapPos = Offset.zero;
  int _downTs = 0;
  int _lastTapTs = 0;
  int _maxPointers = 0;
  double _moved = 0;
  double _scrollAccum = 0;
  double _lastSpan = 0;
  bool _dragActive = false;
  bool _dragPrimed = false;

  InputModel get inputModel => widget.ffi.inputModel;

  @override
  Widget build(BuildContext context) {
    if (!useRawTrackpadLayer) {
      return RawGestureDetector(
        child: widget.child,
        gestures: widget.nativeGestures,
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }

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
    if (_pointers.length == 1) {
      _downPos = e.localPosition;
      _downTs = _now;
      _lastFocal = e.localPosition;
      _moved = 0;
      _scrollAccum = 0;
      _maxPointers = 1;
      _dragActive = false;
      return;
    }
    if (_pointers.length > _maxPointers) {
      _maxPointers = _pointers.length;
    }
    _lastFocal = _focalPoint();
    _lastSpan = _span();
    if (_dragActive) {
      _dragActive = false;
      _dragPrimed = false;
      inputModel.tapUp(MouseButtons.left);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;

    if (_maxPointers >= 2) {
      _moveTwoFingers();
      return;
    }

    // One finger: move the cursor right away, zero slop.
    _moved += e.delta.distance;
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

  void _moveTwoFingers() {
    final focal = _focalPoint();
    final dy = focal.dy - _lastFocal.dy;
    _lastFocal = focal;
    final span = _span();
    final spanChanged =
        _lastSpan > 0 && (span - _lastSpan).abs() > 0.12 * _lastSpan;
    _lastSpan = span;
    _moved += dy.abs();
    if (spanChanged) {
      // Pinch is not handled yet, ignore instead of jumping the wheel.
      _scrollAccum = 0;
      return;
    }
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
    if (_pointers.isNotEmpty) return;

    if (_dragActive) {
      _dragActive = false;
      _dragPrimed = false;
      inputModel.tapUp(MouseButtons.left);
    } else if (isTap) {
      if (_maxPointers >= 2) {
        inputModel.tap(MouseButtons.right);
        _dragPrimed = false;
        _lastTapTs = 0;
      } else if (_now - _lastTapTs <= _doubleTapMs &&
          (_lastTapPos - _downPos).distance < 40) {
        // Second tap: the following move becomes a drag.
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

    _maxPointers = 0;
    _moved = 0;
    _scrollAccum = 0;
    _lastSpan = 0;
    _lastFocal = Offset.zero;
  }

  void _onCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) return;
    if (_dragActive) {
      inputModel.tapUp(MouseButtons.left);
    }
    _dragActive = false;
    _dragPrimed = false;
    _maxPointers = 0;
    _moved = 0;
    _scrollAccum = 0;
    _lastSpan = 0;
    _lastFocal = Offset.zero;
  }
}
