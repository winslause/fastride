import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ride_model.dart';
import '../shared/custom_modal.dart';
import '../theme.dart';

/// =========================================================================
/// EarningsSummarySheet
/// -------------------------------------------------------------------------
/// Clean financial breakdown for the driver.
///
/// Two modes:
///   • Periodic — Today / This week / This month (opened from nav bar).
///   • Post-trip — highlights the trip that just ended.
///
/// No charts. No heavy visualisations. Just clear numbers, tabbed
/// so drivers can scan quickly between time ranges.
/// =========================================================================
class EarningsSummarySheet extends StatefulWidget {
  const EarningsSummarySheet({
    super.key,
    this.todayTrips = 0,
    this.todayEarnings = 0,
    this.lastTrip,
  });

  final int todayTrips;
  final double todayEarnings;

  /// Populated when the sheet is shown right after a trip ends.
  final RideModel? lastTrip;

  static Future<void> show({
    required BuildContext context,
    int todayTrips = 0,
    double todayEarnings = 0,
    RideModel? lastTrip,
  }) {
    return AppSheet.show<void>(
      context: context,
      isScrollControlled: true,
      child: EarningsSummarySheet(
        todayTrips: todayTrips,
        todayEarnings: todayEarnings,
        lastTrip: lastTrip,
      ),
    );
  }

  @override
  State<EarningsSummarySheet> createState() => _EarningsSummarySheetState();
}

class _EarningsSummarySheetState extends State<EarningsSummarySheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  // -- Derived demo data ----------------------------------------------------
  // Real numbers come from the backend. These mirror the widget's inputs so
  // the sheet is fully usable before the analytics endpoint is wired.

  double get _weekEarnings => widget.todayEarnings * 6.1;
  int get _weekTrips => widget.todayTrips * 6;

  double get _monthEarnings => widget.todayEarnings * 24.3;
  int get _monthTrips => widget.todayTrips * 24;

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
          // Header
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
                    widget.lastTrip != null
                        ? 'Trip completed'
                        : 'Earnings',
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

          // Post-trip banner
          if (widget.lastTrip != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceXl,
                0,
                AppTheme.spaceXl,
                AppTheme.spaceLg,
              ),
              child: _lastTripCard(theme, scheme),
            ),

          // Tabs
          TabBar(
            controller: _tabs,
            labelStyle: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: theme.textTheme.labelLarge,
            indicatorSize: TabBarIndicatorSize.tab,
            tabs: const [
              Tab(text: 'Today'),
              Tab(text: 'This week'),
              Tab(text: 'This month'),
            ],
          ),

          const SizedBox(height: AppTheme.spaceLg),

          // Tab views
          Flexible(
            child: TabBarView(
              controller: _tabs,
              children: [
                _panel(
                  theme,
                  scheme,
                  earnings: widget.todayEarnings,
                  trips: widget.todayTrips,
                  label: 'Today',
                ),
                _panel(
                  theme,
                  scheme,
                  earnings: _weekEarnings,
                  trips: _weekTrips,
                  label: 'This week',
                ),
                _panel(
                  theme,
                  scheme,
                  earnings: _monthEarnings,
                  trips: _monthTrips,
                  label: 'This month',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Post-trip card
  // -------------------------------------------------------------------------

  Widget _lastTripCard(ThemeData theme, ColorScheme scheme) {
    final ride = widget.lastTrip!;
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: AppTheme.success.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: AppTheme.success,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'You earned',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      ride.fareLabel,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.success,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spaceLg),
          Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: AppTheme.spaceMd),
          _row(
            theme,
            scheme,
            'From',
            ride.pickup.displayLabel,
          ),
          const SizedBox(height: AppTheme.spaceXs),
          _row(
            theme,
            scheme,
            'To',
            ride.dropoff.displayLabel,
          ),
          const SizedBox(height: AppTheme.spaceXs),
          _row(
            theme,
            scheme,
            'Distance',
            ride.distanceLabel,
          ),
          const SizedBox(height: AppTheme.spaceXs),
          _row(
            theme,
            scheme,
            'Duration',
            ride.durationLabel,
          ),
        ],
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    ColorScheme scheme,
    String label,
    String value,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Period panel
  // -------------------------------------------------------------------------

  Widget _panel(
    ThemeData theme,
    ColorScheme scheme, {
    required double earnings,
    required int trips,
    required String label,
  }) {
    final avg = trips == 0 ? 0.0 : earnings / trips;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceXl,
        0,
        AppTheme.spaceXl,
        AppTheme.spaceXl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero total
          Container(
            padding: const EdgeInsets.all(AppTheme.spaceXl),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onPrimary.withValues(alpha: 0.85),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '\$${earnings.toStringAsFixed(2)}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppTheme.spaceLg),

          // Breakdown grid
          Row(
            children: [
              Expanded(
                child: _stat(
                  theme,
                  scheme,
                  icon: Icons.local_taxi_rounded,
                  label: 'Trips',
                  value: '$trips',
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: _stat(
                  theme,
                  scheme,
                  icon: Icons.trending_up_rounded,
                  label: 'Avg / trip',
                  value: '\$${avg.toStringAsFixed(2)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spaceMd),
          Row(
            children: [
              Expanded(
                child: _stat(
                  theme,
                  scheme,
                  icon: Icons.access_time_rounded,
                  label: 'Online hrs',
                  value: trips == 0 ? '0h' : '${(trips * 0.55).toStringAsFixed(1)}h',
                ),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: _stat(
                  theme,
                  scheme,
                  icon: Icons.star_rounded,
                  label: 'Rating',
                  value: '4.9',
                ),
              ),
            ],
          ),

          const SizedBox(height: AppTheme.spaceXl),

          // Payout note
          Container(
            padding: const EdgeInsets.all(AppTheme.spaceLg),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Text(
                    'Payouts are settled every Monday. Cash trips are '
                    'deducted from your next transfer.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppTheme.spaceXl),

          // CTA
          SheetPrimaryButton(
            label: 'Withdraw earnings',
            icon: Icons.account_balance_rounded,
            onPressed: () {
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Withdrawals coming soon')),
              );
            },
          ),
        ],
      ),
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
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(height: AppTheme.spaceMd),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}