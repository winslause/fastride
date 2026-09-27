import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../theme.dart';

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
  });

  final ApiClient api;
  final RideLocation pickup;
  final RideLocation dropoff;
  final VehicleClass vehicleClass;
  final double fare;
  final double distanceMeters;
  final double durationSeconds;

  static Future<RideModel?> show({
    required BuildContext context,
    required ApiClient api,
    required RideLocation pickup,
    required RideLocation dropoff,
    required VehicleClass vehicleClass,
    required double fare,
    required double distanceMeters,
    required double durationSeconds,
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

class _MatchingSheetState extends State<MatchingSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _tick;
  Timer? _timeout;
  int _elapsed = 0;
  CancelToken? _cancelToken;
  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });

    _timeout = Timer(AppConstants.matchingTimeout, () {
      if (!mounted || _settling) return;
      _cancelToken?.cancel();
      Navigator.of(context).pop(null);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _requestRide());
  }

  @override
  void dispose() {
    _pulse.dispose();
    _tick?.cancel();
    _timeout?.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _requestRide() async {
    final token = CancelToken();
    _cancelToken = token;

    try {
      final ride = await _simulateMatch();

      if (!mounted || token.isCancelled) return;
      _settling = true;
      _tick?.cancel();
      _timeout?.cancel();
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(ride);
    } on ApiException catch (e) {
      if (!mounted || token.isCancelled) return;
      _settling = true;
      _tick?.cancel();
      _timeout?.cancel();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
      Navigator.of(context).pop(null);
    } catch (_) {
      if (!mounted || token.isCancelled) return;
      _settling = true;
      _tick?.cancel();
      _timeout?.cancel();
      Navigator.of(context).pop(null);
    }
  }

  Future<RideModel> _simulateMatch() async {
    await Future<void>.delayed(const Duration(seconds: 1));

    final now = DateTime.now();

    final drivers = await widget.api.getNearbyDrivers(
      lat: widget.pickup.lat,
      lng: widget.pickup.lng,
      radiusKm: 10,
      limit: 20,
    );

    NearbyDriver? driver;
    if (drivers.isNotEmpty) {
      drivers.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      driver = drivers.first;
    }

    final driverModel = driver != null
        ? DriverModel(
            id: driver.id,
            fullName: driver.fullName,
            phone: driver.phone,
            rating: driver.rating,
            totalTrips: driver.totalTrips,
            isVerified: driver.isVerified,
            isOnline: true,
            latitude: driver.latitude,
            longitude: driver.longitude,
            lastSeenAt: driver.lastSeenAt,
            vehicle: driver.vehicle,
          )
        : DriverModel(
            id: 'drv_fallback_${now.millisecondsSinceEpoch}',
            fullName: 'Samuel Mwangi',
            phone: '+254712345678',
            rating: 4.9,
            totalTrips: 1284,
            isVerified: true,
            isOnline: true,
            latitude: widget.pickup.lat + 0.0035,
            longitude: widget.pickup.lng + 0.0028,
            lastSeenAt: now,
            vehicle: const VehicleInfo(
              make: 'Toyota',
              model: 'Corolla',
              plateNumber: 'KDA 123A',
              color: 'Silver',
              year: 2019,
              vehicleClass: VehicleClass.standard,
            ),
          );

    return RideModel(
      id: 'ride_${now.millisecondsSinceEpoch}',
      riderId: 'rider_self',
      state: RideState.accepted,
      pickup: widget.pickup,
      dropoff: widget.dropoff,
      driverId: driverModel.id,
      driver: driverModel,
      vehicleClass: widget.vehicleClass,
      fareEstimate: widget.fare,
      currency: 'KES',
      distanceMeters: widget.distanceMeters,
      durationSeconds: widget.durationSeconds,
      requestedAt: now.subtract(const Duration(seconds: 3)),
      acceptedAt: now,
      otp: '4821',
    );
  }

  void _cancelAndPop() {
    HapticFeedback.lightImpact();
    _cancelToken?.cancel();
    Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);

    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              _radar(theme, scheme),
              const SizedBox(height: AppTheme.spaceXl * 1.5),
              Text(
                'Finding your driver',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Text(
                'Matching you with the closest available driver…',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: AppTheme.spaceXl),
              _timerBadge(theme, scheme),
              const Spacer(),
              _cancelButton(theme, scheme),
              SizedBox(height: media.padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  Widget _radar(ThemeData theme, ColorScheme scheme) {
    return SizedBox(
      width: 220,
      height: 220,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) {
          return Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                _ring(delay: i / 3, scheme: scheme),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.5),
                      blurRadius: 30,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.local_taxi_rounded,
                  color: Colors.white,
                  size: 38,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _ring({required double delay, required ColorScheme scheme}) {
    final t = (_pulse.value + delay) % 1.0;
    final scale = 0.6 + (t * 0.6);
    final opacity = (1.0 - t).clamp(0.0, 1.0);
    return Opacity(
      opacity: opacity * 0.55,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: scheme.primary, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _timerBadge(ThemeData theme, ColorScheme scheme) {
    final remaining = (AppConstants.matchingTimeout.inSeconds - _elapsed)
        .clamp(0, AppConstants.matchingTimeout.inSeconds);
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

  Widget _cancelButton(ThemeData theme, ColorScheme scheme) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: _cancelAndPop,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.5)),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
        child: const Text(
          'Cancel search',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}