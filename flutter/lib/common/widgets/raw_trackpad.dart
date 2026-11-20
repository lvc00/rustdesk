import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// UU-style touch input layer for the RustDesk Android client.
///
/// A raw `Listener` state machine that bypasses the Flutter gesture arena,
/// `kPanSlop`, `ScaleGestureRecognizer` and the 200ms debounce:
///
///   one finger move        -> move the remote cursor immediately
///   one finger tap         -> left click
///   one finger long press  -> right click
///   double tap + move      -> drag (left button held)
///   two finger move        -> wheel scroll
///   two finger pinch       -> zoom the remote screen
///   two finger drag zoomed -> pan the zoomed canvas
///   two finger tap         -> right click
///   three finger tap       -> show / hide the native toolbar
///
/// There is no extra UI in this file any more: the visible controls are the
/// stock RustDesk bottom bar, restyled in `remote_page.dart`.
///
/// Flip [useRawTrackpadLayer] to false to fall back to the stock gesture-arena
/// path.
bool useRawTrackpadLayer = true;

/// Bumped by a three finger tap. `RemotePage` listens to it and toggles its own
/// bottom bar, so the gesture layer needs no reference to the page state.
final ValueNotifier<int> uuToolbarToggleTick = ValueNotifier<int>(0);

/// Two finger gesture mode, decided per gesture so a scroll never turns into a
/// canvas pan half way through.
enum _TwoMode { undecided, scroll, pinch, pan }

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

  /// A pinch must move the finger span at least this much (logical px) *and*
  /// at least [_pinchSpanRate] of the span at gesture start. Two fingers on
  /// glass wobble a few px while scrolling, so a small absolute threshold made
  /// zoom fire during normal two finger scrolling.
  static const double _pinchSpanMinPx = 30.0;
  static const double _pinchSpanRate = 0.12;

  /// Weight of the sliding window used to tell "the fingers are spreading" from
  /// "the pair is travelling". Per frame: `win = win * _winDecay + delta`.
  static const double _winDecay = 0.7;

  /// Only allow two finger panning when the canvas is clearly zoomed in.
  static const double _panMinScale = 1.12;

  /// How long to observe a two finger gesture before locking it as scroll/pan.
  static const int _twoModeLockMs = 100;

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
  double _spanStart = 0;
  double _spanTravel = 0;
  double _focalTravel = 0;

  /// Sliding window (decayed sums) of span change and focal travel, used to see
  /// which movement dominates *right now*. Cumulative sums cannot do this: a
  /// scroll of 300px would keep blocking a pinch that starts afterwards.
  double _winSpan = 0;
  double _winFocal = 0;
  bool _dragActive = false;
  bool _dragPrimed = false;
  bool _longPressed = false;
  bool _threeFinger = false;
  _TwoMode _twoMode = _TwoMode.undecided;
  Timer? _longPressTimer;

  InputModel get inputModel => widget.ffi.inputModel;
  CanvasModel get canvasModel => widget.ffi.canvasModel;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return useRawTrackpadLayer
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
  }

  // =====================================================================
  //  Gesture state machine
  // =====================================================================

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
    _spanStart = _lastSpan;
    _spanTravel = 0;
    _focalTravel = 0;
    _winSpan = 0;
    _winFocal = 0;
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
    final prev = _lastSpan;
    final ratio = prev > 1.0 ? span / prev : 1.0;
    final dSpan = prev > 0 ? (span - prev).abs() : 0.0;
    _lastSpan = span;
    _moved += deltaDistance;

    _focalTravel += Offset(dx, dy).distance;
    _spanTravel += dSpan;
    _winSpan = _winSpan * _winDecay + dSpan;
    _winFocal = _winFocal * _winDecay + Offset(dx, dy).distance;

    // Decide the mode by what dominates the gesture. A pinch needs a real,
    // sustained spread of the fingers: enough span change in total (absolute
    // and relative to the starting span) and a sliding window in which the
    // span moves faster than the pair travels. Two finger scrolling keeps the
    // span almost constant, so it can no longer be mistaken for a zoom, while
    // a pinch still takes over immediately — even right after a scroll.
    if (_twoMode != _TwoMode.pinch) {
      final need = _spanStart * _pinchSpanRate > _pinchSpanMinPx
          ? _spanStart * _pinchSpanRate
          : _pinchSpanMinPx;
      final pinchLike = _spanStart > 60.0 &&
          _spanTravel > need &&
          _winSpan > 3.5 &&
          _winSpan > _winFocal * 1.2;
      if (pinchLike) {
        _twoMode = _TwoMode.pinch;
        _scrollAccum = 0;
        // Apply the zoom accumulated before the mode was decided, otherwise a
        // slow pinch would start zooming only from the moment it was detected.
        // Clamp so late detection cannot make the picture jump.
        var pending = _spanStart > 1.0 ? span / _spanStart : 1.0;
        if (pending < 0.91) pending = 0.91;
        if (pending > 1.10) pending = 1.10;
        if ((pending - 1).abs() > 0.01) {
          canvasModel.updateScale(pending, focal + _globalOffset);
        }
        return;
      }
      if (_twoMode == _TwoMode.undecided &&
          _now - _twoStartTs > _twoModeLockMs) {
        // Lock as scroll/pan. Only a clearly zoomed canvas may be panned, so a
        // slightly drifted scale value never steals the scroll gesture.
        _twoMode =
            canvasModel.scale > _panMinScale ? _TwoMode.pan : _TwoMode.scroll;
        if (_twoMode == _TwoMode.pan) _scrollAccum = 0;
      }
    }

    switch (_twoMode) {
      case _TwoMode.pinch:
        // Zoom only: panning while pinching looks like the window is dragged.
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
      if (_moved < _tapSlop * 4) {
        uuToolbarToggleTick.value = uuToolbarToggleTick.value + 1;
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
    _spanStart = 0;
    _spanTravel = 0;
    _focalTravel = 0;
    _winSpan = 0;
    _winFocal = 0;
    _lastFocal = Offset.zero;
  }
}
