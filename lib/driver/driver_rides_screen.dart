import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/api_client.dart';
import '../models/ride_model.dart';
import '../theme.dart';

/// =========================================================================
/// DriverRidesScreen
/// -------------------------------------------------------------------------
/// "My rides" for the driver: how many trips they've made, and the list of
/// them. This is the same ride history the rider sees, from the other side.
/// =========================================================================
class DriverRidesScreen extends StatefulWidget {
  const DriverRidesScreen({
    super.key,
    required this.api,
    this.fallbackStats,
    this.onResumeRide,
  });

  final ApiClient api;
  final DriverRidesSummary? fallbackStats;

  /// Called when an unfinished ride is tapped, so the dashboard can put the
  /// driver back on the map.
  final void Function(RideModel ride)? onResumeRide;

  /// A ride that has not finished yet. Tapping it puts the driver back on the
  /// map with the route — this is how a trip interrupted by signing out (or a
  /// closed app) is picked back up.
  static bool isOngoing(RideState state) => switch (state) {
        RideState.accepted ||
        RideState.driverArriving ||
        RideState.driverArrived ||
        RideState.ongoing =>
          true,
        _ => false,
      };

  @override
  State<DriverRidesScreen> createState() => _DriverRidesScreenState();
}

class _DriverRidesScreenState extends State<DriverRidesScreen> {
  List<RideModel> _rides = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final rides = await widget.api.fetchDriverRides();
      if (!mounted) return;
      setState(() {
        _rides = rides;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your rides.';
      });
    }
  }

  int get _completedCount =>
      _rides.where((r) => r.state == RideState.completed).length;

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppTheme.spaceMd),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        children: [
          _summaryRow(),
          const SizedBox(height: AppTheme.spaceLg),
          if (_rides.isEmpty)
            _emptyState()
          else
            ..._rides.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.spaceMd),
                  child: _rideCard(r),
                )),
        ],
      ),
    );
  }

  Widget _summaryRow() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fallback = widget.fallbackStats;

    return Row(
      children: [
        Expanded(
          child: _stat(
            theme,
            scheme,
            icon: Icons.local_taxi_rounded,
            label: 'Total rides',
            value: '${fallback?.totalRides ?? _rides.length}',
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: _stat(
            theme,
            scheme,
            icon: Icons.check_circle_rounded,
            label: 'Completed',
            value: '$_completedCount',
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        Expanded(
          child: _stat(
            theme,
            scheme,
            icon: Icons.today_rounded,
            label: 'Today',
            value: '${fallback?.todayRides ?? 0}',
          ),
        ),
      ],
    );
  }

  Widget _stat(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            value,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.space2xl),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: AppTheme.spaceLg),
          Text('No rides yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            'Go online and start accepting requests — completed trips show up here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// A ride that has not finished yet. Tapping it puts the driver back on the
  /// map with the route — this is how a trip interrupted by signing out (or a
  /// closed app) is picked back up.
  Widget _rideCard(RideModel ride) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ongoing = DriverRidesScreen.isOngoing(ride.state);
    final (stateLabel, stateColor) = switch (ride.state) {
      RideState.completed => ('Completed', AppTheme.success),
      RideState.cancelled => ('Cancelled', AppTheme.danger),
      RideState.ongoing => ('On trip', AppTheme.info),
      RideState.accepted => ('Accepted', AppTheme.info),
      RideState.driverArriving => ('Heading to pickup', AppTheme.info),
      RideState.driverArrived => ('At pickup', AppTheme.warning),
      _ => (_titleCase(ride.state.wire), scheme.primary),
    };

    final when = ride.completedAt ?? ride.requestedAt;
    final dateLabel = when == null
        ? ''
        : DateFormat('d MMM, HH:mm').format(when.toLocal());

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: ongoing
            ? BorderSide(color: AppTheme.info.withValues(alpha: 0.6), width: 1.4)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        onTap: ongoing
            ? () {
                HapticFeedback.mediumImpact();
                widget.onResumeRide?.call(ride);
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppTheme.radiusPill),
                  ),
                  child: Text(
                    stateLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: stateColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const Spacer(),
                if (dateLabel.isNotEmpty)
                  Text(
                    dateLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceMd),
            _stop(theme, scheme, Icons.person_pin_circle_rounded,
                ride.pickup.displayLabel),
            const SizedBox(height: AppTheme.spaceSm),
            _stop(theme, scheme, Icons.place_rounded, ride.dropoff.displayLabel),
            const SizedBox(height: AppTheme.spaceMd),
            Row(
              children: [
                if (ride.rider?.fullName.isNotEmpty == true)
                  Expanded(
                    child: Text(
                      'Rider · ${ride.rider!.fullName}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                Text(
                  ride.fareLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.success,
                  ),
                ),
              ],
            ),
            if (ongoing) ...[
              const SizedBox(height: AppTheme.spaceMd),
              Row(
                children: [
                  Icon(
                    Icons.touch_app_rounded,
                    size: 16,
                    color: AppTheme.info,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Tap to return to the map and continue this trip',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppTheme.info,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _stop(
    ThemeData theme,
    ColorScheme scheme,
    IconData icon,
    String label,
  ) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppTheme.danger),
        const SizedBox(width: AppTheme.spaceSm),
        Expanded(
          child: Text(
            label.isEmpty ? '—' : label,
            style: theme.textTheme.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  static String _titleCase(String raw) {
    if (raw.isEmpty) return raw;
    return raw[0].toUpperCase() + raw.substring(1);
  }
}

/// Lightweight snapshot of the driver's counters, so the screen can show
/// numbers immediately while the ride list is still loading.
class DriverRidesSummary {
  const DriverRidesSummary({
    this.totalRides = 0,
    this.todayRides = 0,
    this.todayEarnings = 0,
  });

  final int totalRides;
  final int todayRides;
  final double todayEarnings;
}
