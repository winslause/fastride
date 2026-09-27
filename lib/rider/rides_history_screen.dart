import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/auth_service.dart';
import '../../theme.dart';

class RidesHistoryScreen extends StatefulWidget {
  const RidesHistoryScreen({super.key});

  @override
  State<RidesHistoryScreen> createState() => _RidesHistoryScreenState();
}

class _RidesHistoryScreenState extends State<RidesHistoryScreen> {
  late final ApiClient _api;
  late AuthService _auth;
  bool _ready = false;
  bool _loading = false;
  String? _error;
  List<RideHistoryItem> _allRides = [];
  List<RideHistoryItem> _completedRides = [];
  List<RideHistoryItem> _cancelledRides = [];

  @override
  void initState() {
    super.initState();
    _api = ApiClient(
      baseUrl: const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://127.0.0.1:8000',
      ),
      osrmBaseUrl: const String.fromEnvironment(
        'OSRM_BASE_URL',
        defaultValue: 'https://router.project-osrm.org',
      ),
      geocoderBaseUrl: const String.fromEnvironment(
        'GEOCODER_BASE_URL',
        defaultValue: 'https://photon.komoot.io',
      ),
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _auth = AuthService(api: _api);
    await _auth.initialize();
    if (!mounted) return;
    setState(() => _ready = true);
    _loadRides();
  }

  Future<void> _loadRides() async {
    setState(() => _loading = true);
    try {
      final all = await _api.getRideHistory();
      setState(() {
        _allRides = all;
        _completedRides =
            all.where((r) => r.state == 'completed').toList(growable: false);
        _cancelledRides =
            all.where((r) => r.state == 'cancelled').toList(growable: false);
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Something went wrong. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!_ready) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: scheme.primary),
        ),
      );
    }

    final user = _auth.user;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ride History')),
        body: Center(
          child: TextButton.icon(
            onPressed: () =>
                Navigator.of(context).pushReplacementNamed('/auth'),
            icon: const Icon(Icons.login_rounded),
            label: const Text('Sign in'),
          ),
        ),
      );
    }

    return DefaultTabComponent(
      children: [
        _buildTab(
          theme,
          scheme,
          title: 'All rides',
          rides: _allRides,
          loading: _loading,
          error: _error,
        ),
        _buildTab(
          theme,
          scheme,
          title: 'Completed',
          rides: _completedRides,
          loading: _loading,
          error: _error,
          highlightColor: AppTheme.success,
        ),
        _buildTab(
          theme,
          scheme,
          title: 'Cancelled',
          rides: _cancelledRides,
          loading: _loading,
          error: _error,
          highlightColor: AppTheme.danger,
        ),
      ],
      tabLabels: const ['All', 'Completed', 'Cancelled'],
    );
  }

  Widget _buildTab(
    ThemeData theme,
    ColorScheme scheme, {
    required String title,
    required List<RideHistoryItem> rides,
    required bool loading,
    String? error,
    Color? highlightColor,
  }) {
    if (loading && rides.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && rides.isEmpty) {
      return Center(
        child: Text(
          error,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (rides.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              title == 'Completed'
                  ? Icons.check_circle_outline_rounded
                  : title == 'Cancelled'
                      ? Icons.cancel_outlined
                      : Icons.receipt_long_outlined,
              size: 56,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppTheme.spaceLg),
            Text(
              'No ${title.toLowerCase()} rides',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadRides,
      child: ListView.separated(
        padding: const EdgeInsets.all(AppTheme.spaceXl),
        itemCount: rides.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppTheme.spaceMd),
        itemBuilder: (_, i) {
          final ride = rides[i];
          return _rideTile(theme, scheme, ride, highlightColor);
        },
      ),
    );
  }

  Widget _rideTile(
    ThemeData theme,
    ColorScheme scheme,
    RideHistoryItem ride,
    Color? highlightColor,
  ) {
    final dateFmt = DateFormat('MMM d, y');

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ride.pickupPlace?.isNotEmpty == true
                          ? ride.pickupPlace!
                          : 'Pickup',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (ride.requestedAt != null)
                    Text(
                      dateFmt.format(ride.requestedAt!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '— ${ride.dropoffPlace ?? "Destination"}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: AppTheme.spaceSm),
              Row(
                children: [
                  Expanded(
                    child: _rideMetric(
                      theme,
                      Icons.route_rounded,
                      ride.displayDistance,
                    ),
                  ),
                  Expanded(
                    child: _rideMetric(
                      theme,
                      Icons.schedule_rounded,
                      ride.displayDuration,
                    ),
                  ),
                  Expanded(
                    child: _rideMetric(
                      theme,
                      Icons.currency_bitcoin_rounded,
                      ride.displayFare,
                    ),
                  ),
                  Chip(
                    label: Text(
                      ride.stateLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: highlightColor ?? scheme.primary,
                      ),
                    ),
                    backgroundColor:
                        (highlightColor ?? scheme.primary).withValues(alpha: 0.12),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  ),
                ],
              ),
              if (ride.driverName != null) ...[
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  '${ride.driverName!}${ride.driverRating != null ? ' · ★ ${ride.driverRating!.toStringAsFixed(1)}' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _rideMetric(ThemeData theme, IconData icon, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class DefaultTabComponent extends StatelessWidget {
  const DefaultTabComponent({
    super.key,
    required this.children,
    required this.tabLabels,
  });

  final List<Widget> children;
  final List<String> tabLabels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride History'),
        centerTitle: true,
        bottom: TabBar(
          tabs: tabLabels.map((l) => Tab(text: l)).toList(),
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          indicator: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: scheme.primary,
                width: 3,
              ),
            ),
          ),
        ),
      ),
      body: TabBarView(children: children),
    );
  }
}
