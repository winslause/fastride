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
/// "Choose your ride". Shows the drivers who are online right now, each
/// priced for this whole trip from the rate card they set in the driver app.
/// There are no vehicle classes to pick — the rider picks a person.
/// =========================================================================
class FareSelectSheet extends StatefulWidget {
  const FareSelectSheet({
    super.key,
    required this.api,
    required this.route,
    required this.pickup,
    required this.dropoff,
    required this.pickupLabel,
    required this.dropoffLabel,
  });

  final ApiClient api;
  final OsrmRoute route;
  final RideLocation pickup;
  final RideLocation dropoff;
  final String pickupLabel;
  final String dropoffLabel;

  static Future<FareSelection?> show({
    required BuildContext context,
    required ApiClient api,
    required OsrmRoute route,
    required RideLocation pickup,
    required RideLocation dropoff,
    required String pickupLabel,
    required String dropoffLabel,
  }) {
    return AppSheet.show<FareSelection>(
      context: context,
      isScrollControlled: true,
      child: FareSelectSheet(
        api: api,
        route: route,
        pickup: pickup,
        dropoff: dropoff,
        pickupLabel: pickupLabel,
        dropoffLabel: dropoffLabel,
      ),
    );
  }

  @override
  State<FareSelectSheet> createState() => _FareSelectSheetState();
}

class _FareSelectSheetState extends State<FareSelectSheet> {
  List<NearbyDriver> _drivers = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDrivers());
  }

  /// The total for the whole trip, from that driver's own per-kilometre rate.
  double _totalFor(NearbyDriver d) => d.quoteFor(
        distanceMeters: widget.route.distanceMeters,
        durationSeconds: widget.route.durationSeconds,
      );

  Future<void> _loadDrivers() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final drivers = await widget.api.getNearbyDrivers(
        lat: widget.pickup.lat,
        lng: widget.pickup.lng,
        radiusKm: 15,
        limit: 30,
        tripDistanceMeters: widget.route.distanceMeters,
        tripDurationSeconds: widget.route.durationSeconds,
      );

      if (!mounted) return;
      final sorted = [...drivers]..sort(
            (a, b) => _totalFor(a).compareTo(_totalFor(b)),
          );
      setState(() {
        _drivers = sorted;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load nearby drivers.';
      });
    }
  }

  void _choose(NearbyDriver d) {
    HapticFeedback.mediumImpact();
    final vehicleClass = d.vehicle?.vehicleClass ?? VehicleClass.standard;
    Navigator.of(context).pop(
      FareSelection(
        vehicleClass: vehicleClass,
        fare: _totalFor(d),
        driver: d,
      ),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose your ride',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _distanceLabel(widget.route.distanceMeters) +
                            ' · ' +
                            _durationLabel(widget.route.durationSeconds),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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

          // --- Drivers ---
          Flexible(
            child: _buildList(theme, scheme),
          ),

          const SizedBox(height: AppTheme.spaceMd),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppTheme.space2xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_drivers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spaceXl,
          AppTheme.spaceLg,
          AppTheme.spaceXl,
          AppTheme.space2xl,
        ),
        child: Column(
          children: [
            Icon(
              Icons.person_search_rounded,
              size: 44,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Text(
              _error ?? 'No drivers are online nearby right now',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.spaceLg),
            OutlinedButton.icon(
              onPressed: _loadDrivers,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Check again'),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
      itemCount: _drivers.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppTheme.spaceSm),
      itemBuilder: (_, i) => _driverTile(theme, scheme, _drivers[i], i),
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

  // -------------------------------------------------------------------------
  // Driver tile — name, phone, and the total for the whole trip
  // -------------------------------------------------------------------------

  Widget _driverTile(
    ThemeData theme,
    ColorScheme scheme,
    NearbyDriver d,
    int index,
  ) {
    final total = _totalFor(d);

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        onTap: () => _choose(d),
        child: Container(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(
              color: index == 0
                  ? scheme.primary.withValues(alpha: 0.6)
                  : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: scheme.primary.withValues(alpha: 0.14),
                child: Text(
                  _initials(d.fullName),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.spaceLg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.fullName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (d.isVerified) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.verified_rounded,
                            size: 15,
                            color: scheme.primary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.phone_rounded,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            d.phone.isEmpty ? 'No number' : d.phone,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (_metaFor(d).isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _metaFor(d),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              // Total for the whole trip
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _money(total),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  Text(
                    d.pricing.currency,
                    style: theme.textTheme.labelSmall?.copyWith(
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

  /// Rating, distance and the rate that produced the total.
  String _metaFor(NearbyDriver d) {
    final parts = <String>[
      if (d.rating > 0) '★ ${d.rating.toStringAsFixed(1)}',
      if (d.distanceMeters > 0) '${_distanceLabel(d.distanceMeters)} away',
      '${_money(d.pricing.pricePerKm)}/km',
    ];
    return parts.join('  ·  ');
  }

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  static String _money(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  static String _distanceLabel(double meters) {
    if (meters <= 0) return '0 m';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  static String _durationLabel(double seconds) {
    final m = (seconds / 60).round();
    if (m < 60) return '$m min';
    return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }
}

/// Payload returned to the dashboard once the rider has picked a driver.
class FareSelection {
  const FareSelection({
    required this.vehicleClass,
    required this.fare,
    this.driver,
  });

  final VehicleClass vehicleClass;

  /// The quoted total for the whole trip.
  final double fare;

  /// The driver the rider chose. Null only if something upstream did not
  /// provide a live driver list.
  final NearbyDriver? driver;

  String? get driverId => driver?.id;
}
