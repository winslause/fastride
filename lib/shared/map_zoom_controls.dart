import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../theme.dart';

/// Vertical zoom in / zoom out control pair for the flutter_map based screens.
///
/// Pinch, double tap and scroll wheel gestures keep working through the map's
/// own `InteractiveFlag` options; these buttons are the discoverable fallback
/// for users who do not know the gesture or are using a trackpad.
class MapZoomControls extends StatefulWidget {
  const MapZoomControls({
    super.key,
    required this.controller,
    this.minZoom = AppConstants.mapMinZoom,
    this.maxZoom = AppConstants.mapMaxZoom,
    this.step = 1,
    this.spacing = AppTheme.spaceSm,
    this.compact = false,
  });

  final MapController controller;
  final double minZoom;
  final double maxZoom;
  final double step;
  final double spacing;

  /// Tighter buttons for maps that only get a short strip of screen space.
  final bool compact;

  @override
  State<MapZoomControls> createState() => _MapZoomControlsState();
}

class _MapZoomControlsState extends State<MapZoomControls>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  Animation<double>? _zoomAnimation;

  @override
  void initState() {
    super.initState();
    _anim
      ..addListener(_applyZoom)
      ..addStatusListener((status) {
        // Only `completed` retires a tween. `forward(from: 0)` rewinds the
        // controller to zero, which reports `dismissed` synchronously, so
        // reacting to that here would cancel the very zoom we just requested.
        if (status != AnimationStatus.completed) return;

        final animation = _zoomAnimation;
        _zoomAnimation = null;

        // Land exactly on the target. The curve and the map's own clamping can
        // leave a fraction of a level on the table, and the next tap would
        // then start from the wrong place.
        if (animation == null || !mounted) return;
        _moveCameraTo(animation.value);
      });
  }

  void _applyZoom() {
    if (_zoomAnimation == null || !mounted) return;
    _moveCameraTo(_zoomAnimation!.value);
  }

  void _moveCameraTo(double zoom) {
    // The camera is only valid once the map has been laid out.
    final camera = widget.controller.camera;
    if (camera.zoom <= 0) return;

    widget.controller.move(
      camera.center,
      zoom.clamp(widget.minZoom, widget.maxZoom),
    );
  }

  void _zoomBy(double delta) {
    final current = widget.controller.camera.zoom;
    if (current <= 0) return;

    final target = (current + delta).clamp(
      widget.minZoom.toDouble(),
      widget.maxZoom,
    );
    if ((target - current).abs() < 0.01) return;

    _anim.stop();
    final animation = Tween<double>(begin: current, end: target).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );

    _anim.forward(from: 0);
    // Assigned after the controller is running, so the synchronous rewind
    // above cannot null it out before the first frame is drawn.
    _zoomAnimation = animation;
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(
          icon: Icons.add_rounded,
          tooltip: 'Zoom in',
          onTap: () => _zoomBy(widget.step),
        ),
        if (!widget.compact)
          Padding(
            padding: EdgeInsets.symmetric(vertical: widget.spacing / 2),
            child: Container(
              width: 22,
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          )
        else
          const SizedBox(height: 6),
        _button(
          icon: Icons.remove_rounded,
          tooltip: 'Zoom out',
          onTap: () => _zoomBy(-widget.step),
        ),
      ],
    );
  }

  Widget _button({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surface,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(widget.compact ? 7 : 12),
            child: Icon(icon, size: 20, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}
