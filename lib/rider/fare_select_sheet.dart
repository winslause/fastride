import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../shared/custom_modal.dart';
import '../theme.dart';

/// =========================================================================
/// FareSelectSheet
/// -------------------------------------------------------------------------
/// Shows the route preview (distance, duration) and a list of vehicle
/// classes with deterministic prices. Selecting one returns a
/// `FareSelection` to the dashboard, which then opens the matching sheet.
/// =========================================================================
class FareSelectSheet extends StatefulWidget {
  const FareSelectSheet({
    super.key,
    required this.route,
    required this.pickupLabel,
    required this.dropoffLabel,
  });

  final OsrmRoute route;
  final String pickupLabel;
  final String dropoffLabel;

  static Future<FareSelection?> show({
    required BuildContext context,
    required OsrmRoute route,
    required String pickupLabel,
    required String dropoffLabel,
  }) {
    return AppSheet.show<FareSelection>(
      context: context,
      isScrollControlled: true,
      child: FareSelectSheet(
        route: route,
        pickupLabel: pickupLabel,
        dropoffLabel: dropoffLabel,
      ),
    );
  }

  @override
  State<FareSelectSheet> createState() => _FareSelectSheetState();
}

class _FareSelectSheetState extends State<FareSelectSheet> {
  /// All classes shown to the rider. Deterministic, sorted by price.
  static const List<VehicleClass> _classes = [
    VehicleClass.moto,
    VehicleClass.standard,
    VehicleClass.xl,
    VehicleClass.premium,
  ];

  VehicleClass _selected = VehicleClass.standard;

  /// The one and only fare computation used across the app.
  double _fareFor(VehicleClass c) {
    return FareCalculator.calculate(
      distanceMeters: widget.route.distanceMeters,
      durationSeconds: widget.route.durationSeconds,
      vehicleClass: c,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // --- Header ---
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceXl,
              AppTheme.spaceSm,
              AppTheme.spaceMd,
              AppTheme.spaceSm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose your ride',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // --- Route summary card ---
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spaceXl,
            ),
            child: _routeSummary(theme, scheme),
          ),

          const SizedBox(height: AppTheme.spaceLg),

          // --- Vehicle class list ---
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spaceXl,
              ),
              itemCount: _classes.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppTheme.spaceSm),
              itemBuilder: (_, i) {
                final c = _classes[i];
                return _vehicleTile(theme, scheme, c);
              },
            ),
          ),

          const SizedBox(height: AppTheme.spaceMd),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Route summary
  // -------------------------------------------------------------------------

  Widget _routeSummary(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Trip endpoints
          Row(
            children: [
              _dot(scheme.primary),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Text(
                  widget.pickupLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Container(
              width: 2,
              height: 18,
              color: scheme.outlineVariant,
            ),
          ),
          Row(
            children: [
              _dot(AppTheme.danger),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Text(
                  widget.dropoffLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          const SizedBox(height: AppTheme.spaceLg),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppTheme.spaceMd),

          // Distance + duration
          Row(
            children: [
              _metric(
                theme,
                scheme,
                Icons.route_rounded,
                _distanceLabel(widget.route.distanceMeters),
              ),
              const SizedBox(width: AppTheme.spaceXl),
              _metric(
                theme,
                scheme,
                Icons.schedule_rounded,
                _durationLabel(widget.route.durationSeconds),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 6),
        ],
      ),
    );
  }

  Widget _metric(
    ThemeData theme,
    ColorScheme scheme,
    IconData icon,
    String value,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Vehicle tile
  // -------------------------------------------------------------------------

  Widget _vehicleTile(
    ThemeData theme,
    ColorScheme scheme,
    VehicleClass c,
  ) {
    final selected = c == _selected;
    final fare = _fareFor(c);

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _selected = c);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
              width: 1.6,
            ),
          ),
          child: Row(
            children: [
              // Vehicle icon tile
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.16)
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(
                  _iconFor(c),
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  size: 26,
                ),
              ),
              const SizedBox(width: AppTheme.spaceLg),
              // Labels
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          c.label,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        if (c == VehicleClass.standard) ...[
                          const SizedBox(width: 8),
                          _badge(theme, scheme, 'Popular'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      c.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              // Price
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                   Text(
                     CurrencySymbols.of('KES') + fare.toStringAsFixed(0),
                     style: theme.textTheme.titleMedium?.copyWith(
                       fontWeight: FontWeight.w800,
                       color: scheme.onSurface,
                     ),
                   ),
                  Text(
                    _etaFor(c),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(VehicleClass c) {
    switch (c) {
      case VehicleClass.moto:
        return Icons.two_wheeler_rounded;
      case VehicleClass.standard:
        return Icons.directions_car_rounded;
      case VehicleClass.xl:
        return Icons.airport_shuttle_rounded;
      case VehicleClass.premium:
        return Icons.local_taxi_rounded;
    }
  }

  Widget _badge(ThemeData theme, ColorScheme scheme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  /// Deterministic ETA — pure maths from the route duration.
  String _etaFor(VehicleClass c) {
    final baseMin = (widget.route.durationSeconds / 60).round();
    final offset = switch (c) {
      VehicleClass.moto => baseMin - 2,
      VehicleClass.standard => baseMin,
      VehicleClass.xl => baseMin + 2,
      VehicleClass.premium => baseMin + 3,
    };
    final safe = offset < 1 ? 1 : offset;
    return '$safe min away';
  }

  String _distanceLabel(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _durationLabel(double seconds) {
    final m = (seconds / 60).round();
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return '${h}h ${r.toString().padLeft(2, '0')}m';
  }
}

/// Payload returned to the dashboard when the rider confirms a class.
class FareSelection {
  const FareSelection({
    required this.vehicleClass,
    required this.fare,
  });

  final VehicleClass vehicleClass;
  final double fare;
}