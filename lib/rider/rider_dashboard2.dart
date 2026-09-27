import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/auth_service.dart';
import '../core/location_service.dart';
import '../core/websocket_client.dart';
import '../models/ride_model.dart';
import '../theme.dart';
import 'active_trip_sheet.dart';
import 'destination_sheet.dart';
import 'fare_select_sheet.dart';
import 'help_screen.dart';
import 'matching_sheet.dart';
import 'profile_screen.dart' show showChangePasswordDialog, showEditProfile;
import 'promotions_screen.dart';
import 'safety_screen.dart';
import 'wallet_screen.dart';

// =========================================================================
// RIDER DASHBOARD
// =========================================================================

/// The single consolidated rider dashboard.
///
/// Layout:
///   • Wide (≥ 900px): permanent sidebar (rail or expanded) + map on the right.
///   • Narrow: map full screen + hamburger toggling a slide-in drawer.
///
/// Owns the state machine that switches the four overlay sheets:
///   destination → fare → matching → active trip.
class RiderDashboardView extends StatefulWidget {
  const RiderDashboardView({super.key});

  @override
  State<RiderDashboardView> createState() => _RiderDashboardViewState();
}

class _RiderDashboardViewState extends State<RiderDashboardView>
    with WidgetsBindingObserver {
  // --- Dependencies --------------------------------------------------------
  late final ApiClient _api;
  late final LocationService _location;
  late AuthService _auth;

  // --- Controllers ---------------------------------------------------------
  final MapController _mapController = MapController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // --- Responsive breakpoint ----------------------------------------------
  static const double _wideBreakpoint = 900;
  bool _sidebarExpanded = true;

  // --- Map ------------------------------------------------------------------
  static const LatLng _fallbackCenter = LatLng(1.2921, 36.8219);
  LatLng _center = _fallbackCenter;
  LatLng? _pickup;
  LatLng? _dropoff;
  bool _mapReady = false;
  bool _followingUser = true;

  // --- Flow state -----------------------------------------------------------
  RiderState _state = RiderState.draft;
  RideLocation? _pickupLocation;
  RideLocation? _dropoffLocation;
  OsrmRoute? _route;
  RideModel? _ride;

  // --- Streams --------------------------------------------------------------
  StreamSubscription<Position>? _posSub;
  StreamSubscription<WsEvent>? _wsSub;
  StreamSubscription<WsStatus>? _wsStatusSub;
  Timer? _locationSyncTimer;

  // --- UI state -------------------------------------------------------------
  int _navIndex = 0;
  bool _loadingRoute = false;
  WsStatus _wsStatus = WsStatus.disconnected;

  // --- Recents (loaded from backend) ---------------------------------------
  List<_RecentTrip> _recents = const [];
  bool _recentsLoading = true;
  String? _recentsError;

  // =========================================================================
  // Lifecycle
  // =========================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _location = LocationService();
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationSyncTimer?.cancel();
    _posSub?.cancel();
    _wsSub?.cancel();
    _wsStatusSub?.cancel();
    _api.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.paused) {
      _posSub?.pause();
    } else if (lifecycleState == AppLifecycleState.resumed) {
      _posSub?.resume();
    }
  }

  // =========================================================================
  // Bootstrap
  // =========================================================================

  Future<void> _bootstrap() async {
    _auth = AuthService(
      api: _api,
      preferences: await SharedPreferences.getInstance(),
    );
    await _auth.initialize();

    final status = await _location.ensureReady();
    if (!mounted) return;

    if (!status.isUsable) {
      _showLocationBanner(status);
      return;
    }

    final last = await _location.lastKnown();
    Position? pos = last;
    if (pos == null && mounted) {
      pos = await _location.current();
    }
    if (pos != null && mounted) {
      final here = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _center = here;
        _pickup = here;
      });
      _safeMove(here);
      _reverseGeocodePickup(here);
    } else if (mounted) {
      setState(() {
        _pickup = _center;
      });
    }

    await _loadRecents();

    _posSub = _location.positionStream().listen((pos) {
      if (!mounted) return;
      final here = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _center = here;
        if (_state == RiderState.draft && _pickup == null) {
          _pickup = here;
        }
      });
      if (_followingUser && _state == RiderState.draft) {
        _safeMove(here);
      }
    });

    _locationSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncLocation();
    });
  }

  Future<void> _reverseGeocodePickup(LatLng here) async {
    try {
      final place = await _api.reverseGeocode(
        lat: here.latitude,
        lng: here.longitude,
      );
      if (!mounted || place == null) return;
      setState(() {
        _pickupLocation = RideLocation(
          lat: place.lat,
          lng: place.lng,
          address: place.secondary,
          placeName: place.primary,
        );
      });
    } catch (_) {
      // Non-fatal — raw coordinates are still shown.
    }
  }

  Future<void> _loadRecents() async {
    if (!mounted) return;
    setState(() {
      _recentsLoading = true;
      _recentsError = null;
    });

    try {
      final history = await _api.getRideHistory(limit: 5);
      if (!mounted) return;
      final recents = <_RecentTrip>[];
      for (final ride in history) {
        final icon = _iconForPlace(ride.pickupPlace);
        recents.add(_RecentTrip(
          ride.pickupPlace ?? 'Unknown pickup',
          ride.dropoffPlace ?? 'Unknown destination',
          ride.displayFare,
          icon,
        ));
      }
      if (!mounted) return;
      setState(() {
        _recents = recents;
        _recentsLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _recents = const [];
        _recentsLoading = false;
        _recentsError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recents = const [];
        _recentsLoading = false;
        _recentsError = 'Could not load ride history.';
      });
    }
  }

  IconData _iconForPlace(String? place) {
    final lower = (place ?? '').toLowerCase();
    if (lower.contains('airport') || lower.contains('jkia')) {
      return Icons.flight_rounded;
    }
    if (lower.contains('home') || lower.contains('karen')) {
      return Icons.home_rounded;
    }
    if (lower.contains('work') ||
        lower.contains('ave') ||
        lower.contains('street')) {
      return Icons.work_rounded;
    }
    return Icons.place_rounded;
  }

  Future<void> _syncLocation() async {
    if (!mounted) return;
    if (!_auth.isReady) return;
    if (!_auth.isAuthenticated) return;
    if (kIsWeb && _center == _fallbackCenter) return;
    if (_center == _fallbackCenter) return;
    try {
      await _api.saveLocation(
        lat: _center.latitude,
        lng: _center.longitude,
      );
    } catch (_) {}
  }

  // =========================================================================
  // Map helpers
  // =========================================================================

  void _safeMove(LatLng target, {double? zoom}) {
    if (!_mapReady) return;
    try {
      _mapController.move(target, zoom ?? _mapController.camera.zoom);
    } catch (_) {}
  }

  void _recenterOnUser() {
    if (_center == _fallbackCenter) return;
    setState(() => _followingUser = true);
    _safeMove(_center, zoom: 16);
    HapticFeedback.selectionClick();
  }

  void _fitBounds(LatLng a, LatLng b) {
    if (!_mapReady) return;
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([a, b]),
          padding: const EdgeInsets.fromLTRB(60, 160, 60, 340),
          maxZoom: 16,
        ),
      );
    } catch (_) {}
  }

  // =========================================================================
  // Flow transitions
  // =========================================================================

  Future<void> _openDestinationSheet({bool forPickup = false}) async {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    final result = await DestinationSheet.show(
      context: context,
      api: _api,
      bias: _center,
    );
    if (result == null || !mounted) return;

    if (forPickup) {
      setState(() {
        _pickup = LatLng(result.lat, result.lng);
        _pickupLocation = RideLocation(
          lat: result.lat,
          lng: result.lng,
          address: result.secondary,
          placeName: result.primary,
        );
      });
      _safeMove(LatLng(result.lat, result.lng));
      return;
    }

    setState(() {
      _dropoff = LatLng(result.lat, result.lng);
      _dropoffLocation = RideLocation(
        lat: result.lat,
        lng: result.lng,
        address: result.secondary,
        placeName: result.primary,
      );
      _state = RiderState.searching;
    });

    await _fetchRouteAndPrice();
  }

  Future<void> _fetchRouteAndPrice() async {
    if (_pickup == null || _dropoff == null) return;
    if (!mounted) return;
    setState(() => _loadingRoute = true);
    final from = _pickup!;
    final to = _dropoff!;

    try {
      final route = await _api.route(
        fromLat: from.latitude,
        fromLng: from.longitude,
        toLat: to.latitude,
        toLng: to.longitude,
      );
      if (!mounted) return;
      setState(() {
        _route = route;
        _loadingRoute = false;
        _followingUser = false;
      });
      _fitBounds(from, to);
      await Future<void>.delayed(const Duration(milliseconds: 340));
      if (!mounted) return;
      await _openFareSheet(route);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRoute = false;
        _state = RiderState.draft;
      });
      _toast(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingRoute = false;
        _state = RiderState.draft;
      });
      _toast('Could not fetch route. Please try again.');
    }
  }

  Future<void> _openFareSheet(OsrmRoute route) async {
    if (!mounted) return;
    setState(() => _state = RiderState.pricing);

    final selection = await FareSelectSheet.show(
      context: context,
      route: route,
      pickupLabel: _pickupLocation?.displayLabel ?? 'Pickup',
      dropoffLabel: _dropoffLocation?.displayLabel ?? 'Destination',
    );
    if (!mounted) return;

    if (selection == null) {
      _resetToIdle();
      return;
    }
    await _openMatchingSheet(selection);
  }

  Future<void> _openMatchingSheet(FareSelection selection) async {
    if (_pickupLocation == null || _dropoffLocation == null) return;
    if (!mounted) return;
    setState(() => _state = RiderState.matching);

    final ride = await MatchingSheet.show(
      context: context,
      api: _api,
      pickup: _pickupLocation!,
      dropoff: _dropoffLocation!,
      vehicleClass: selection.vehicleClass,
      fare: selection.fare,
      distanceMeters: _route?.distanceMeters ?? 0,
      durationSeconds: _route?.durationSeconds ?? 0,
    );

    if (!mounted) return;

    if (ride == null) {
      _resetToIdle();
      return;
    }

    setState(() {
      _ride = ride;
      _state = RiderState.trip;
    });

    await _openActiveTripSheet(ride);
  }

  Future<void> _openActiveTripSheet(RideModel ride) async {
    if (!mounted) return;
    final outcome = await ActiveTripSheet.show(
      context: context,
      ride: ride,
      api: _api,
    );

    if (!mounted) return;

    switch (outcome) {
      case ActiveTripOutcome.completed:
        _toast('Thanks for riding with us!');
        _resetToIdle();
      case ActiveTripOutcome.cancelled:
        _toast('Ride cancelled.');
        _resetToIdle();
      case null:
        break;
    }
  }

  void _resetToIdle() {
    setState(() {
      _state = RiderState.draft;
      _route = null;
      _dropoff = null;
      _dropoffLocation = null;
      _ride = null;
      _followingUser = true;
    });
    if (_pickup != null) _safeMove(_pickup!, zoom: 15);
  }

  // =========================================================================
  // Utilities
  // =========================================================================

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showLocationBanner(LocationStatus status) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.location_off_rounded, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    status.message,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Fix',
          onPressed: () {
            if (status == LocationStatus.serviceDisabled) {
              _location.openLocationSettings();
            } else {
              _location.openAppSettings();
            }
          },
        ),
      ),
    );
  }

  // =========================================================================
  // BUILD — main content area
  // =========================================================================

  Widget _buildMapContent({required bool isWide}) {
    return Stack(
      children: [
        _buildMap(),
        _buildTopBar(isWide: isWide),
        _buildMapControls(isWide: isWide),
        if (_state == RiderState.draft) _buildIdleOverlay(isWide: isWide),
        _buildBottomArea(),
      ],
    );
  }

  Widget _buildSecondaryContent() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final titles = {
      1: 'My Rides',
      2: 'Wallet',
      3: 'Promotions',
      4: 'Safety',
      5: 'Help',
      6: 'Settings',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceMd,
          ),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
          ),
          child: Text(
            titles[_navIndex] ?? 'Dashboard',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: switch (_navIndex) {
            1 => _buildRidesContent(theme, scheme),
            2 => const WalletScreen(),
            3 => const PromotionsScreen(),
            4 => const SafetyScreen(),
            5 => const HelpScreen(),
            6 => _buildSettingsContent(theme, scheme),
            _ => const Center(child: Text('Unknown section')),
          },
        ),
      ],
    );
  }

  Widget _buildRidesContent(ThemeData theme, ColorScheme scheme) {
    if (_recentsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_recentsError != null) {
      return Center(
        child: Text(
          _recentsError!,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    if (_recents.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 56,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppTheme.spaceLg),
            Text(
              'No rides yet',
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      itemCount: _recents.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppTheme.spaceMd),
      itemBuilder: (_, i) {
        final r = _recents[i];
        return Card(
          child: ListTile(
            leading: Icon(r.icon, size: 32, color: scheme.primary),
            title: Text(r.from, style: theme.textTheme.titleMedium),
            subtitle: Text(r.to, style: theme.textTheme.bodySmall),
            trailing: Text(
              r.price,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
            onTap: () {
              HapticFeedback.selectionClick();
              _toast('Opening "${r.from} → ${r.to}"');
            },
          ),
        );
      },
    );
  }

  Widget _buildSettingsContent(ThemeData theme, ColorScheme scheme) {
    final user = _auth.user;
    if (user == null) {
      return const SizedBox.shrink();
    }

    return ListView(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      children: [
        ListTile(
          leading: Icon(Icons.person_outline_rounded, color: scheme.primary),
          title: const Text('Edit profile'),
          onTap: () {
            final ctx = _scaffoldKey.currentContext;
            if (ctx == null) return;
            Navigator.of(ctx).pop();
            showEditProfile(
              context: ctx,
              auth: _auth,
              api: _api,
            );
          },
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(Icons.lock_outline_rounded, color: scheme.primary),
          title: const Text('Change password'),
          onTap: () {
            final ctx = _scaffoldKey.currentContext;
            if (ctx == null) return;
            Navigator.of(ctx).pop();
            showChangePasswordDialog(
              context: ctx,
              auth: _auth,
            );
          },
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout_rounded, color: AppTheme.danger),
          title: Text(
            'Sign out',
            style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.danger),
          ),
          onTap: () => _logout(),
        ),
      ],
    );
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (!mounted) return;
    Navigator.of(_scaffoldKey.currentContext!)
      ..popUntil((route) => route.isFirst)
      ..pushReplacementNamed('/auth');
  }


  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isWide = width >= _wideBreakpoint;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        key: _scaffoldKey,
        extendBody: true,
        drawer: isWide
            ? null
            : _buildDrawer(expanded: true, isDrawer: true),
        body: SafeArea(
          bottom: false,
          child: Row(
            children: [
              // --- Sidebar (wide only) ---
              if (isWide)
                AnimatedContainer(
                  duration: AppConstants.sheetDuration,
                  curve: Curves.easeOutCubic,
                  width: _sidebarExpanded ? 260 : 84,
                  child: _buildSidebarRail(),
                ),

           // --- Main content ---
           Expanded(
             child: ClipRRect(
               borderRadius: isWide
                   ? const BorderRadius.horizontal(
                       left: Radius.circular(AppTheme.radiusLg),
                     )
                   : BorderRadius.zero,
               child: _navIndex == 0
                   ? _buildMapContent(isWide: isWide)
                   : _buildSecondaryContent(),
             ),
           ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // SIDEBAR (wide) — expands/collapses via hamburger
  // -------------------------------------------------------------------------

  Widget _buildSidebarRail() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Brand + toggle ---
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceLg,
              AppTheme.spaceSm,
              AppTheme.spaceMd,
              AppTheme.spaceMd,
            ),
            child: Row(
              children: [
                if (_sidebarExpanded)
                  Expanded(
                    child: Row(
                      children: [
                        _brandMark(scheme),
                        const SizedBox(width: AppTheme.spaceMd),
                        Flexible(
                          child: Text(
                            'FastRide',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _brandMark(scheme),
                IconButton(
                  tooltip: _sidebarExpanded ? 'Collapse' : 'Expand',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() => _sidebarExpanded = !_sidebarExpanded);
                  },
                  icon: Icon(
                    _sidebarExpanded
                        ? Icons.menu_open_rounded
                        : Icons.menu_rounded,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),

          // --- Nav items ---
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spaceSm,
                vertical: AppTheme.spaceSm,
              ),
              children: [
                _navTile(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  selected: _navIndex == 0,
                  onTap: () => setState(() => _navIndex = 0),
                ),
                _navTile(
                  icon: Icons.receipt_long_rounded,
                  label: 'My rides',
                  selected: _navIndex == 1,
                  onTap: () => setState(() => _navIndex = 1),
                ),
                _navTile(
                  icon: Icons.account_balance_wallet_rounded,
                  label: 'Wallet',
                  selected: _navIndex == 2,
                  onTap: () => setState(() => _navIndex = 2),
                ),
                _navTile(
                  icon: Icons.local_offer_rounded,
                  label: 'Promotions',
                  selected: _navIndex == 3,
                  onTap: () => setState(() => _navIndex = 3),
                ),
                _navTile(
                  icon: Icons.shield_rounded,
                  label: 'Safety',
                  selected: _navIndex == 4,
                  onTap: () => setState(() => _navIndex = 4),
                ),
                _navTile(
                  icon: Icons.help_outline_rounded,
                  label: 'Help',
                  selected: _navIndex == 5,
                  onTap: () => setState(() => _navIndex = 5),
                ),
                _navTile(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  selected: _navIndex == 6,
                  onTap: () => setState(() => _navIndex = 6),
                ),
              ],
            ),
          ),

          // --- Switch to driver + footer profile ---
          Padding(
            padding: const EdgeInsets.all(AppTheme.spaceSm),
            child: Column(
              children: [
                _navTile(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Switch to driver',
                  selected: false,
                  onTap: () => _toast('Switch to driver coming soon'),
                ),
                const SizedBox(height: AppTheme.spaceSm),
                Divider(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                  height: 1,
                ),
                const SizedBox(height: AppTheme.spaceSm),
                _profileFooter(scheme, theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandMark(ColorScheme scheme) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.local_taxi_rounded,
        color: scheme.onPrimary,
        size: 22,
      ),
    );
  }

  Widget _navTile({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spaceMd,
              vertical: 12,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (_sidebarExpanded) ...[
                  const SizedBox(width: AppTheme.spaceMd),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileFooter(ColorScheme scheme, ThemeData theme) {
    final user = _auth.user;
    if (user == null) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: () {
          HapticFeedback.selectionClick();
          showEditProfile(
            context: context,
            auth: _auth,
            api: _api,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spaceSm,
            vertical: AppTheme.spaceSm,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  user.initials,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (_sidebarExpanded) ...[
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.fullName,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'View profile',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // DRAWER (mobile)
  // -------------------------------------------------------------------------

  Widget _buildDrawer({required bool expanded, required bool isDrawer}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = _auth.user;

    return Drawer(
      backgroundColor: scheme.surface,
      width: 288,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(AppTheme.radiusLg),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceXl,
                AppTheme.spaceXl,
                AppTheme.spaceLg,
                AppTheme.spaceLg,
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      user?.initials ?? '?',
                      style: theme.textTheme.titleLarge?.copyWith(
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
                        Text(
                          user?.fullName ?? 'Guest',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'View profile',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: scheme.outlineVariant.withValues(alpha: 0.5)),

            // Items
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  vertical: AppTheme.spaceSm,
                ),
                children: [
                  _drawerNavTile(Icons.home_rounded, 'Home', 0),
                  _drawerNavTile(Icons.receipt_long_rounded, 'My rides', 1),
                  _drawerNavTile(Icons.account_balance_wallet_rounded, 'Wallet', 2),
                  _drawerNavTile(Icons.local_offer_rounded, 'Promotions', 3),
                  _drawerNavTile(Icons.shield_rounded, 'Safety centre', 4),
                  _drawerNavTile(Icons.help_outline_rounded, 'Help & support', 5),
                  _drawerNavTile(Icons.settings_outlined, 'Settings', 6),
                  const SizedBox(height: AppTheme.spaceMd),
                  Divider(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                    height: 1,
                  ),
                  const SizedBox(height: AppTheme.spaceMd),
                  _drawerTile(
                    icon: Icons.swap_horiz_rounded,
                    label: 'Switch to driver',
                    onTap: () {
                      Navigator.of(_scaffoldKey.currentContext!).pop();
                      Future.microtask(() {
                        if (mounted) _toast('Switch to driver coming soon');
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spaceLg,
        vertical: 2,
      ),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }

  Widget _drawerNavTile(IconData icon, String label, int index) {
    return _drawerTile(
      icon: icon,
      label: label,
      onTap: () {
        Navigator.of(_scaffoldKey.currentContext!).pop();
        Future.microtask(() {
          if (mounted) setState(() => _navIndex = index);
        });
      },
    );
  }

  // -------------------------------------------------------------------------
  // MAP
  // -------------------------------------------------------------------------

  Widget _buildMap() {
    final scheme = Theme.of(context).colorScheme;
    const tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _center,
        initialZoom: 15,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () {
          _mapReady = true;
          _safeMove(_center, zoom: 15);
        },
        onPositionChanged: (position, hasGesture) {
          if (hasGesture && _followingUser) {
            setState(() => _followingUser = false);
          }
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.doubleTapZoom |
              InteractiveFlag.flingAnimation |
              InteractiveFlag.pinchMove,
        ),
        onTap: (_, __) => FocusScope.of(context).unfocus(),
      ),
      children: [
        TileLayer(
          urlTemplate: tileUrl,
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.fastride.app',
          maxNativeZoom: 19,
        ),
        if (_route != null && _route!.polyline.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _route!.polyline
                    .map<LatLng>((p) => LatLng(p.lat, p.lng))
                    .toList(),
                strokeWidth: 5,
                color: scheme.primary,
                borderStrokeWidth: 2,
                borderColor: Colors.white,
              ),
            ],
          ),
         MarkerLayer(
          markers: [
            // My current position marker (small red)
            _currentLocationMarker(_center),
            // Pickup point (when selected) — blue
            if (_pickup != null)
              _marker(
                point: _pickup!,
                color: const Color(0xFF00A67E),
                icon: Icons.place_rounded,
                size: 36,
              ),
            // Dropoff point — red
            if (_dropoff != null && _state != RiderState.draft)
              _marker(
                point: _dropoff!,
                color: AppTheme.danger,
                icon: Icons.place_rounded,
                size: 36,
              ),
          ],
        ),
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [
            TextSourceAttribution('OpenStreetMap contributors'),
          ],
        ),
      ],
    );
  }

  Marker _marker({
    required LatLng point,
    required Color color,
    required IconData icon,
    double size = 46,
  }) {
    return Marker(
      point: point,
      width: size,
      height: size,
      alignment: Alignment.center,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: AppTheme.softShadow,
          border: Border.all(color: color, width: 3),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }

  Marker _currentLocationMarker(LatLng point) {
    return Marker(
      point: point,
      width: 20,
      height: 20,
      alignment: Alignment.center,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.danger,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: AppTheme.softShadow,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // TOP BAR (map overlay)
  // -------------------------------------------------------------------------

  Widget _buildTopBar({required bool isWide}) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spaceLg,
          AppTheme.spaceSm,
          AppTheme.spaceLg,
          AppTheme.spaceSm,
        ),
        child: Row(
          children: [
            if (!isWide) ...[
              _hamburgerButton(),
              const SizedBox(width: AppTheme.spaceSm),
            ],
            Expanded(child: _statusPill()),
            const SizedBox(width: AppTheme.spaceSm),
            _walletChip(),
            const SizedBox(width: AppTheme.spaceSm),
            _notificationsButton(),
          ],
        ),
      ),
    );
  }

  Widget _hamburgerButton() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          HapticFeedback.selectionClick();
          _scaffoldKey.currentState?.openDrawer();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.menu_rounded,
            size: 22,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _notificationsButton() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _toast('Notifications coming soon'),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(
                Icons.notifications_none_rounded,
                size: 22,
                color: scheme.onSurface,
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: AppTheme.danger,
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.surface, width: 1.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _walletChip() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() => _navIndex = 2);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_balance_wallet_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Wallet & payments',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (label, dot) = switch (_state) {
      RiderState.draft => (
          _wsStatus == WsStatus.connected ? 'Online' : 'Where to?',
          _wsStatus == WsStatus.connected ? AppTheme.success : scheme.primary,
        ),
      RiderState.searching => ('Finding your route…', AppTheme.info),
      RiderState.pricing => ('Choose your ride', scheme.primary),
      RiderState.matching => ('Matching you…', AppTheme.warning),
      RiderState.trip => (_ride?.state.label ?? 'On the trip', AppTheme.success),
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // MAP CONTROLS
  // -------------------------------------------------------------------------

  Widget _buildMapControls({required bool isWide}) {
    return Positioned(
      right: AppTheme.spaceLg,
      bottom: isWide ? 240 : 300,
      child: Column(
        children: [
          _mapControlButton(
            icon: _followingUser
                ? Icons.my_location_rounded
                : Icons.location_searching_rounded,
            tooltip: 'Recenter',
            onTap: _recenterOnUser,
            highlighted: _followingUser,
          ),
        ],
      ),
    );
  }

  Widget _mapControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: highlighted ? scheme.primary : scheme.surface,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(
              icon,
              size: 20,
              color: highlighted ? scheme.onPrimary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // IDLE OVERLAY
  // -------------------------------------------------------------------------

  Widget _buildIdleOverlay({required bool isWide}) {
    return Positioned(
      left: AppTheme.spaceLg,
      right: AppTheme.spaceLg,
      bottom: isWide ? 200 : 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
         children: [
           _recentStrip(),
         ],
       ),
     );
   }

  Widget _recentStrip() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (_recentsLoading) {
      return const SizedBox(
        height: 96,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_recentsError != null) {
      return const SizedBox(height: 1, child: SizedBox.shrink());
    }

    if (_recents.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _recents.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppTheme.spaceMd),
        itemBuilder: (_, i) {
          final r = _recents[i];
          return InkWell(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            onTap: () {
              HapticFeedback.selectionClick();
              _toast('Opening "${r.from} → ${r.to}"');
            },
            child: Container(
              width: 200,
              padding: const EdgeInsets.all(AppTheme.spaceMd),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                boxShadow: AppTheme.softShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(r.icon, size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          r.from,
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.place_rounded,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          r.to,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    r.price,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // BOTTOM AREA
  // -------------------------------------------------------------------------

  Widget _buildBottomArea() {
    final hideNav = _state != RiderState.draft;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedSlide(
        offset: hideNav ? const Offset(0, 1) : Offset.zero,
        duration: AppConstants.sheetDuration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: hideNav ? 0 : 1,
          duration: AppConstants.sheetDuration,
          child: _bottomPanel(),
        ),
      ),
    );
  }

  Widget _bottomPanel() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLg),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 24,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceLg,
          ),
          child: _searchAnchor(),
        ),
      ),
    );
  }

  Widget _searchAnchor() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: _loadingRoute ? null : () => _openDestinationSheet(),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spaceLg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Icon(
                _loadingRoute
                    ? Icons.hourglass_top_rounded
                    : Icons.search_rounded,
                color: scheme.primary,
                size: 22,
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _loadingRoute ? 'Finding your route…' : 'Where to?',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (_pickupLocation != null &&
                        _pickupLocation!.displayLabel.isNotEmpty)
                      Text(
                        'From ${_pickupLocation!.displayLabel}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =========================================================================
// SUPPORT
// =========================================================================

enum RiderState { draft, searching, pricing, matching, trip }

class _RecentTrip {
  const _RecentTrip(this.from, this.to, this.price, this.icon);
  final String from;
  final String to;
  final String price;
  final IconData icon;
}