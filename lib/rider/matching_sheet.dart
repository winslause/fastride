import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../theme.dart';

/// =========================================================================
/// MatchingSheet — "Choose your ride"
/// -------------------------------------------------------------------------
/// Shows the drivers who are genuinely online right now, priced for this
/// exact trip from their own rate card. The rider picks one, the request is
/// written against that driver, and the sheet waits for them to accept.
/// =========================================================================
class MatchingSheet extends StatefulWidget {
  const MatchingSheet({
    super.key,
    required this.api,
    required this.pickup,
    required this.dropoff,
    required this.vehicleClass,
    required this.fare,
    required this.distanceMeters,
    required this.durationSeconds,
    this.preselectedDriver,
  });

  final ApiClient api;
  final RideLocation pickup;
  final RideLocation dropoff;
  final VehicleClass vehicleClass;

  /// The platform estimate shown before a driver is chosen. Realised once the
  /// rider picks a driver, whose own rate card decides the price.
  final double fare;
  final double distanceMeters;
  final double durationSeconds;

  /// The driver the rider already chose. When present there is nothing left to
  /// pick, so the sheet skips straight to sending the request and waiting.
  final NearbyDriver? preselectedDriver;

  static Future<RideModel?> show({
    required BuildContext context,
    required ApiClient api,
    required RideLocation pickup,
    required RideLocation dropoff,
    required VehicleClass vehicleClass,
    required double fare,
    required double distanceMeters,
    required double durationSeconds,
    NearbyDriver? preselectedDriver,
  }) {
    return showGeneralDialog<RideModel>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: AppConstants.sheetDuration,
      pageBuilder: (_, __, ___) => MatchingSheet(
        api: api,
        pickup: pickup,
        dropoff: dropoff,
        vehicleClass: vehicleClass,
        fare: fare,
        distanceMeters: distanceMeters,
        durationSeconds: durationSeconds,
        preselectedDriver: preselectedDriver,
      ),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    );
  }

  @override
  State<MatchingSheet> createState() => _MatchingSheetState();
}

enum _Stage { choosing, waiting }

class _MatchingSheetState extends State<MatchingSheet> {
  _Stage _stage = _Stage.choosing;

  List<NearbyDriver> _drivers = const [];
  String? _selectedId;
  String? _error;
  bool _loading = true;
  bool _sortCheapest = true;

  RideModel? _ride;
  int _elapsed = 0;
  Timer? _tick;
  Timer? _poll;
  Timer? _timeout;
  CancelToken? _cancelToken;
  bool _settling = false;

  /// The rider's choice, held in a list so the waiting screen can read it
  /// whether it came from this sheet or was passed in.
  List<NearbyDriver> _chosen = const [];

  NearbyDriver? get _selected {
    if (_chosen.isNotEmpty) return _chosen.first;
    for (final d in _drivers) {
      if (d.id == _selectedId) return d;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });

    final preselected = widget.preselectedDriver;
    if (preselected != null) {
      _chosen = [preselected];
      WidgetsBinding.instance.addPostFrameCallback((_) => _request());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDrivers());
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    _timeout?.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Choosing
  // -------------------------------------------------------------------------

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
        tripDistanceMeters: widget.distanceMeters,
        tripDurationSeconds: widget.durationSeconds,
      );

      if (!mounted) return;
      setState(() {
        _drivers = _sorted(drivers);
        _loading = false;
        if (_selectedId != null &&
            !_drivers.any((d) => d.id == _selectedId)) {
          _selectedId = null;
        }
        _selectedId ??= _drivers.isEmpty ? null : _drivers.first.id;
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

  List<NearbyDriver> _sorted(List<NearbyDriver> drivers) {
    final copy = [...drivers];
    if (_sortCheapest) {
      copy.sort((a, b) => _priceOf(a).compareTo(_priceOf(b)));
    } else {
      copy.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    }
    return copy;
  }

  double _priceOf(NearbyDriver d) => d.quoteFor(
        distanceMeters: widget.distanceMeters,
        durationSeconds: widget.durationSeconds,
      );

  FareBreakdown _breakdownOf(NearbyDriver d) =>
      d.fareBreakdown ??
      FareBreakdown.fromPricing(
        d.pricing,
        distanceMeters: widget.distanceMeters,
        durationSeconds: widget.durationSeconds,
      );

  void _toggleSort() {
    HapticFeedback.selectionClick();
    setState(() {
      _sortCheapest = !_sortCheapest;
      _drivers = _sorted(_drivers);
    });
  }

  void _select(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      _chosen = [];
      _selectedId = id;
    });
  }

  // -------------------------------------------------------------------------
  // Requesting + waiting for the driver
  // -------------------------------------------------------------------------

  Future<void> _request() async {
    final driver = _selected;
    if (driver == null) return;

    HapticFeedback.mediumImpact();
    final token = CancelToken();
    _cancelToken = token;

    setState(() {
      _stage = _Stage.waiting;
      _elapsed = 0;
      _error = null;
    });

    try {
      final ride = await widget.api.createRideRequest(
        driverId: driver.id,
        pickup: widget.pickup,
        dropoff: widget.dropoff,
        distanceMeters: widget.distanceMeters,
        durationSeconds: widget.durationSeconds,
        vehicleClass: widget.vehicleClass,
        cancelToken: token,
      );

      if (!mounted || token.isCancelled) return;
      _ride = ride;

      _timeout = Timer(AppConstants.matchingTimeout, () {
        if (!mounted || _settling) return;
        _fail('The driver did not respond in time. Please try again.');
      });

      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _pollOnce());
    } on ApiException catch (e) {
      if (!mounted || token.isCancelled) return;
      _fail(e.message);
    } catch (_) {
      if (!mounted || token.isCancelled) return;
      _fail('Could not send your request. Please try again.');
    }
  }

  Future<void> _pollOnce() async {
    final rideId = _ride?.id;
    if (rideId == null || _settling) return;

    try {
      final ride = await widget.api.getRide(rideId);
      if (!mounted || _settling) return;

      switch (ride.state) {
        case RideState.accepted:
        case RideState.driverArriving:
        case RideState.driverArrived:
        case RideState.ongoing:
        case RideState.completed:
          _succeed(ride);
          break;
        case RideState.expired:
        case RideState.cancelled:
          _fail(ride.cancellationReason ?? 'The driver declined your request.');
          break;
        default:
          break;
      }
    } catch (_) {
      // A dropped poll is not fatal; the next tick retries.
    }
  }

  void _succeed(RideModel ride) {
    if (_settling) return;
    _settling = true;
    _poll?.cancel();
    _timeout?.cancel();
    HapticFeedback.heavyImpact();
    Navigator.of(context).pop(ride);
  }

  void _fail(String message) {
    if (_settling) return;
    _settling = true;
    _poll?.cancel();
    _timeout?.cancel();
    setState(() {
      _stage = _Stage.choosing;
      _error = message;
      _ride = null;
      // Drop the preselected driver so the list reopens with a fresh choice.
      _chosen = const [];
      _selectedId = null;
    });
    // Reload the roster: whoever was picked may now be busy or offline.
    unawaited(_reloadAfterFailure());
  }

  Future<void> _reloadAfterFailure() async {
    _settling = false;
    await _loadDrivers();
  }

  void _cancelAndPop() {
    HapticFeedback.lightImpact();
    _cancelToken?.cancel();
    _poll?.cancel();
    _timeout?.cancel();
    Navigator.of(context).pop(null);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: _stage == _Stage.waiting ? _buildWaiting() : _buildChoosing(),
      ),
    );
  }

  // --- Choose -------------------------------------------------------------

  Widget _buildChoosing() {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final driver = _selected;
    final isWide = media.size.width >= 720;

    return Padding(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme),
          const SizedBox(height: AppTheme.spaceMd),
          _routeSummary(theme),
          const SizedBox(height: AppTheme.spaceMd),
          _sortRow(theme),
          const SizedBox(height: AppTheme.spaceSm),
          Expanded(child: _driverList(theme, isWide)),
          if (_error != null) ...[
            const SizedBox(height: AppTheme.spaceSm),
            _errorBanner(theme, _error!),
          ],
          const SizedBox(height: AppTheme.spaceMd),
          if (driver != null)
            _confirmBar(theme, driver)
          else
            _cancelButton(theme, 'Cancel'),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Choose your ride',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        IconButton(
          onPressed: _loadDrivers,
          icon: const Icon(Icons.refresh_rounded, color: Colors.white),
          tooltip: 'Refresh drivers',
        ),
        IconButton(
          onPressed: _cancelAndPop,
          icon: const Icon(Icons.close_rounded, color: Colors.white),
          tooltip: 'Cancel',
        ),
      ],
    );
  }

  Widget _routeSummary(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _place(theme, Icons.trip_origin_rounded, 'Pickup',
              widget.pickup.displayLabel, widget.pickup.displaySubtitle),
          const SizedBox(height: AppTheme.spaceSm),
          _place(theme, Icons.place_rounded, 'Drop-off',
              widget.dropoff.displayLabel, widget.dropoff.displaySubtitle),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            '${_distanceLabel(widget.distanceMeters)} · '
            '${_durationLabel(widget.durationSeconds)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }

  Widget _place(
    ThemeData theme,
    IconData icon,
    String label,
    String title,
    String subtitle,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.85)),
        const SizedBox(width: AppTheme.spaceSm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.6),
                  letterSpacing: 0.8,
                ),
              ),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sortRow(ThemeData theme) {
    return Row(
      children: [
        Text(
          _drivers.isEmpty
              ? 'No drivers online yet'
              : '${_drivers.length} driver${_drivers.length == 1 ? '' : 's'} online',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
        const Spacer(),
        _sortChip(theme, 'Cheapest', _sortCheapest),
        const SizedBox(width: AppTheme.spaceSm),
        _sortChip(theme, 'Nearest', !_sortCheapest),
      ],
    );
  }

  Widget _sortChip(ThemeData theme, String label, bool active) {
    return GestureDetector(
      onTap: _toggleSort,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spaceMd,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          border: Border.all(
            color: Colors.white.withValues(alpha: active ? 0.55 : 0.2),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: Colors.white,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _driverList(ThemeData theme, bool isWide) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_drivers.isEmpty) {
      return _emptyState(theme);
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
      itemCount: _drivers.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppTheme.spaceSm),
      itemBuilder: (_, i) => _driverCard(theme, _drivers[i], isWide),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.person_search_rounded,
            size: 48,
            color: Colors.white.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppTheme.spaceMd),
          Text(
            'No drivers are online nearby',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            'Drivers appear here as soon as they come online.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: AppTheme.spaceLg),
          OutlinedButton.icon(
            onPressed: _loadDrivers,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Check again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _driverCard(ThemeData theme, NearbyDriver d, bool isWide) {
    final selected = d.id == _selectedId;
    final price = _priceOf(d);
    final breakdown = _breakdownOf(d);
    final cheapest = _sortCheapest && _drivers.isNotEmpty && _drivers.first.id == d.id;
    final vehicle = d.vehicle;

    return GestureDetector(
      onTap: () => _select(d.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(AppTheme.spaceMd),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.18),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                  child: Text(
                    _initials(d.fullName),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              d.fullName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (d.isVerified) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.verified_rounded,
                              size: 15,
                              color: Colors.white,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (vehicle != null &&
                              (vehicle.make.isNotEmpty || vehicle.model.isNotEmpty))
                            '${vehicle.make} ${vehicle.model}'.trim(),
                          if (vehicle != null && vehicle.plateNumber.isNotEmpty)
                            vehicle.plateNumber,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 4),
                      _metaRow(theme, d),
                    ],
                  ),
                ),
                const SizedBox(width: AppTheme.spaceSm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _money(price),
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      d.pricing.currency,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
                if (selected) ...[
                  const SizedBox(width: AppTheme.spaceXs),
                  const Icon(
                    Icons.check_circle_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ],
              ],
            ),
            if (selected) ...[
              const SizedBox(height: AppTheme.spaceSm),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.15)),
              const SizedBox(height: AppTheme.spaceSm),
              _fareLines(theme, breakdown, price, d.pricing),
            ],
            if (cheapest) ...[
              const SizedBox(height: AppTheme.spaceSm),
              _badge(theme, 'Best price', Icons.savings_outlined),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metaRow(ThemeData theme, NearbyDriver d) {
    final parts = <String>[
      if (d.rating > 0) '★ ${d.rating.toStringAsFixed(1)}',
      if (d.totalTrips > 0) '${d.totalTrips} trips',
      if (d.distanceMeters > 0) '${_distanceLabel(d.distanceMeters)} away',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join('  ·  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: Colors.white.withValues(alpha: 0.75),
      ),
    );
  }

  Widget _fareLines(
    ThemeData theme,
    FareBreakdown b,
    double total,
    DriverPricing pricing,
  ) {
    return Column(
      children: [
        _fareLine(theme, 'Base fare', _money(b.baseFare)),
        _fareLine(
          theme,
          'Distance · ${_distanceLabel(widget.distanceMeters)}',
          _money(b.distanceFare),
        ),
        _fareLine(
          theme,
          'Time · ${_durationLabel(widget.durationSeconds)}',
          _money(b.timeFare),
        ),
        if (b.minimumApplied)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Minimum fare applied (${_money(b.minimumFare)} ${b.currency})',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.65),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        const SizedBox(height: 2),
        Row(
          children: [
            Text(
              'Total',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Text(
              '${_money(total)} ${b.currency}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'This driver charges ${_money(pricing.baseFare)} base + '
          '${_money(pricing.pricePerKm)}/km + ${_money(pricing.pricePerMinute)}/min'
          '${pricing.minimumFare > 0 ? ', minimum ${_money(pricing.minimumFare)}' : ''}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _fareLine(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(ThemeData theme, String label, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.85)),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _errorBanner(ThemeData theme, String message) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceMd),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 18, color: theme.colorScheme.error),
          const SizedBox(width: AppTheme.spaceSm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmBar(ThemeData theme, NearbyDriver d) {
    final price = _priceOf(d);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                d.fullName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Total ${_money(price)} ${d.pricing.currency}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppTheme.spaceMd),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _request,
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Request ride'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceLg),
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- Waiting ------------------------------------------------------------

  Widget _buildWaiting() {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final driver = _selected;
    final remaining = (AppConstants.matchingTimeout.inSeconds - _elapsed)
        .clamp(0, AppConstants.matchingTimeout.inSeconds);

    return Padding(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          _waitingAvatar(theme, driver),
          const SizedBox(height: AppTheme.spaceXl),
          Text(
            driver == null
                ? 'Sending your request…'
                : 'Waiting for ${driver.fullName.split(' ').first} to accept',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            driver == null
                ? 'Hang tight.'
                : '${_money(_priceOf(driver))} ${driver.pricing.currency} · '
                    'They have been notified and will appear on your map shortly.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: AppTheme.spaceXl),
          _timerBadge(theme, remaining),
          const Spacer(),
          _cancelButton(theme, 'Cancel request'),
          SizedBox(height: media.padding.bottom),
        ],
      ),
    );
  }

  Widget _waitingAvatar(ThemeData theme, NearbyDriver? driver) {
    return SizedBox(
      width: 150,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < 3; i++)
            TweenAnimationBuilder<double>(
              key: ValueKey('pulse$i'),
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 1800 + i * 400),
              curve: Curves.easeOut,
              onEnd: () {},
              builder: (_, value, __) => Opacity(
                opacity: (1 - value).clamp(0.0, 1.0) * 0.5,
                child: Transform.scale(
                  scale: 0.6 + (value * 0.6),
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          CircleAvatar(
            radius: 44,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            child: Icon(
              Icons.local_taxi_rounded,
              color: Colors.white,
              size: driver == null ? 38 : 0,
            ),
          ),
          if (driver != null)
            Text(
              _initials(driver.fullName),
              style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }

  Widget _timerBadge(ThemeData theme, int remaining) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceLg,
        vertical: AppTheme.spaceSm,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            '${remaining}s',
            style: theme.textTheme.labelLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cancelButton(ThemeData theme, String label) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton(
        onPressed: _cancelAndPop,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  // --- Formatting ---------------------------------------------------------

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
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
