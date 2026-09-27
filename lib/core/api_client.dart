import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/driver_model.dart';
import '../models/ride_model.dart';
import '../models/user_model.dart';

// Re-export LatLng so consumers can import it from this file too.
export 'package:latlong2/latlong.dart' show LatLng;
// Re-export VehicleClass and VehicleInfo so consumers can import from here.
export '../models/driver_model.dart' show VehicleClass, VehicleClassX, VehicleInfo;

/// =========================================================================
/// ApiClient
/// -------------------------------------------------------------------------
/// Single HTTP gateway for every network call in the app:
///   • Backend REST (auth, trips, fares)
///   • OSRM routing (self-hosted or public mirror)
///   • Photon / Nominatim geocoding (free OSM-based)
/// =========================================================================
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.osrmBaseUrl,
    required this.geocoderBaseUrl,
    http.Client? httpClient,
    this.defaultTimeout = const Duration(seconds: 12),
    this.maxRetries = 3,
    this.defaultHeaders = const {},
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String osrmBaseUrl;
  final String geocoderBaseUrl;
  final Duration defaultTimeout;
  final int maxRetries;
  final Map<String, String> defaultHeaders;

  final http.Client _http;

  String? _authToken;
  set authToken(String? token) => _authToken = token;
  String? get authToken => _authToken;

  // =========================================================================
  // PUBLIC API
  // =========================================================================

  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    Duration? timeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) {
    return _send(
      method: 'GET',
      uri: _backendUri(path, query),
      timeout: timeout,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Duration? timeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) {
    return _send(
      method: 'POST',
      uri: _backendUri(path, query),
      body: body,
      timeout: timeout,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  Future<dynamic> patch(
    String path, {
    Object? body,
    Duration? timeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) {
    return _send(
      method: 'PATCH',
      uri: _backendUri(path),
      body: body,
      timeout: timeout,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  Future<dynamic> delete(
    String path, {
    Object? body,
    Duration? timeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) {
    return _send(
      method: 'DELETE',
      uri: _backendUri(path),
      body: body,
      timeout: timeout,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  // -------------------------------------------------------------------------
  // OSRM
  // -------------------------------------------------------------------------

  /// Routes through the **backend** `/route` endpoint, which proxies to
  /// OSRM. Use this instead of [osrmRoute] when the backend is live.
  Future<OsrmRoute> route({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    String profile = 'driving',
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/route', {
        'from_lat': fromLat,
        'from_lng': fromLng,
        'to_lat': toLat,
        'to_lng': toLng,
        'profile': profile,
      }),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );

    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Route response is incomplete.',
      );
    }

    final distance = (json['distance_meters'] as num?)?.toDouble();
    final duration = (json['duration_seconds'] as num?)?.toDouble();
    final coordsList = json['polyline'];

    if (distance == null || duration == null) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Route response is incomplete.',
      );
    }

    final points = <LatLng>[];
    if (coordsList is List) {
      for (final c in coordsList) {
        if (c is Map) {
          final lat = (c['lat'] as num?)?.toDouble();
          final lng = (c['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            points.add(LatLng(lat, lng));
          }
        }
      }
    }

    final segmentsList = json['segments'];
    final segments = <RouteSegment>[];
    if (segmentsList is List) {
      for (final s in segmentsList) {
        if (s is Map) {
          final parsed =
              RouteSegment.fromJson(s.cast<String, dynamic>());
          if (parsed != null) segments.add(parsed);
        }
      }
    }

    return OsrmRoute(
      distanceMeters: distance,
      durationSeconds: duration,
      polyline: points
          .map((p) => (lat: p.latitude, lng: p.longitude))
          .toList(growable: false),
      segments: segments,
    );
  }

  Future<OsrmRoute> osrmRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    List<({double lat, double lng})> waypoints = const [],
    String profile = 'driving',
    CancelToken? cancelToken,
  }) async {
    final coords = <String>[
      '${fromLng.toStringAsFixed(6)},${fromLat.toStringAsFixed(6)}',
      for (final w in waypoints)
        '${w.lng.toStringAsFixed(6)},${w.lat.toStringAsFixed(6)}',
      '${toLng.toStringAsFixed(6)},${toLat.toStringAsFixed(6)}',
    ].join(';');

    final uri = Uri.parse(
      '$osrmBaseUrl/route/v1/$profile/$coords'
      '?overview=full&geometries=geojson&steps=false&annotations=false',
    );

    final json = await _send(
      method: 'GET',
      uri: uri,
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );

    if (json is! Map || json['code'] != 'Ok') {
      throw ApiException(
        kind: ApiErrorKind.server,
        message:
            'OSRM did not return a route (${json is Map ? json['code'] : 'invalid'}).',
      );
    }

    final routes = json['routes'];
    if (routes is! List || routes.isEmpty) {
      throw const ApiException(
        kind: ApiErrorKind.notFound,
        message: 'No route found between the selected points.',
      );
    }

    final first = routes.first as Map;
    final distance = (first['distance'] as num?)?.toDouble();
    final duration = (first['duration'] as num?)?.toDouble();
    final geometry = first['geometry'];

    if (distance == null || duration == null || geometry is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'OSRM returned an incomplete route payload.',
      );
    }

    final coordsList = geometry['coordinates'];
    final points = <LatLng>[];
    if (coordsList is List) {
      for (final c in coordsList) {
        if (c is List && c.length >= 2) {
          final lng = (c[0] as num?)?.toDouble();
          final lat = (c[1] as num?)?.toDouble();
          if (lat != null && lng != null) {
            points.add(LatLng(lat, lng));
          }
        }
      }
    }

    return OsrmRoute(
      distanceMeters: distance,
      durationSeconds: duration,
      polyline: points
          .map((p) => (lat: p.latitude, lng: p.longitude))
          .toList(growable: false),
    );
  }

  Future<List<List<double>>> osrmTable({
    required List<({double lat, double lng})> sources,
    required List<({double lat, double lng})> destinations,
    String profile = 'driving',
    CancelToken? cancelToken,
  }) async {
    if (sources.isEmpty || destinations.isEmpty) return const [];

    final all = [...sources, ...destinations];
    final coords = all
        .map((p) => '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}')
        .join(';');

    final srcIdx = List.generate(sources.length, (i) => i).join(';');
    final dstIdx = List.generate(
      destinations.length,
      (i) => i + sources.length,
    ).join(';');

    final uri = Uri.parse(
      '$osrmBaseUrl/table/v1/$profile/$coords'
      '?sources=$srcIdx&destinations=$dstIdx&annotations=duration,distance',
    );

    final json = await _send(
      method: 'GET',
      uri: uri,
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );

    if (json is! Map || json['code'] != 'Ok') {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'OSRM table request failed.',
      );
    }

    final durations = json['durations'];
    if (durations is! List) return const [];

    final result = <List<double>>[];
    for (final row in durations) {
      if (row is List) {
        result.add(
          row.map<double>((v) => (v as num?)?.toDouble() ?? 0).toList(),
        );
      }
    }
    return result;
  }

  // =========================================================================
  // Ride dispatch
  // -------------------------------------------------------------------------
  // A rider picks an online driver, the ride is created against them with a
  // fare quoted from their rate card, and the driver picks it up by polling
  // `driverOffers`.
  // =========================================================================

  /// Create a ride request assigned to [driverId].
  Future<RideModel> createRideRequest({
    required String driverId,
    required RideLocation pickup,
    required RideLocation dropoff,
    required double distanceMeters,
    required double durationSeconds,
    VehicleClass vehicleClass = VehicleClass.standard,
    String currency = 'KES',
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/rides'),
      body: {
        'driver_id': driverId,
        'vehicle_class': vehicleClass.wire,
        'distance_meters': distanceMeters,
        'duration_seconds': durationSeconds,
        'currency': currency,
        'pickup': {
          'lat': pickup.lat,
          'lng': pickup.lng,
          'place_name': pickup.displayLabel,
          'address': pickup.displaySubtitle,
        },
        'dropoff': {
          'lat': dropoff.lat,
          'lng': dropoff.lng,
          'place_name': dropoff.displayLabel,
          'address': dropoff.displaySubtitle,
        },
      },
      timeout: const Duration(seconds: 12),
      cancelToken: cancelToken,
    );

    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'The server did not return a ride',
      );
    }
    return RideModel.fromJson(json.cast<String, dynamic>());
  }

  /// Live status of a ride. The rider polls this until the driver responds.
  Future<RideModel> getRide(String rideId, {CancelToken? cancelToken}) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/rides/$rideId'),
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'The server did not return a ride',
      );
    }
    return RideModel.fromJson(json.cast<String, dynamic>());
  }

  /// The caller's unfinished ride, for either role. Used to put someone back
  /// on the map after signing out mid-trip. Null when nothing is in progress.
  Future<RideModel?> activeRide({CancelToken? cancelToken}) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/rides/active'),
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );

    if (json is! Map) return null;
    final rideJson = json['ride'];
    if (rideJson is! Map) return null;

    return RideModel.fromJson(rideJson.cast<String, dynamic>());
  }

  /// Where the rider is right now, so the driver can watch their pin move
  /// while driving to the pickup. `live` is null until a fresh fix lands.
  Future<RiderLocation> getRiderLocation(
    String rideId, {
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/rides/$rideId/rider-location'),
      timeout: const Duration(seconds: 6),
      cancelToken: cancelToken,
    );
    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'Could not read the rider position',
      );
    }
    return RiderLocation.fromJson(json.cast<String, dynamic>());
  }

  /// Accept an offer assigned to the signed-in driver.
  Future<RideModel> acceptRide(String rideId, {CancelToken? cancelToken}) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/rides/$rideId/accept'),
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'The server did not return a ride',
      );
    }
    return RideModel.fromJson(json.cast<String, dynamic>());
  }

  /// Turn down an offer assigned to the signed-in driver.
  Future<RideModel> declineRide(
    String rideId, {
    String reason = 'Driver declined the request',
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/rides/$rideId/decline'),
      body: {'reason': reason},
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'The server did not return a ride',
      );
    }
    return RideModel.fromJson(json.cast<String, dynamic>());
  }

  /// Advance a ride: `driver_arriving`, `driver_arrived`, `ongoing`,
  /// `completed` or `cancelled`.
  Future<RideModel> updateRideState(
    String rideId, {
    required RideState state,
    String? reason,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/rides/$rideId/state'),
      body: {
        'state': state.wire,
        if (reason != null) 'reason': reason,
      },
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'The server did not return a ride',
      );
    }
    return RideModel.fromJson(json.cast<String, dynamic>());
  }

  /// Rate the driver on a finished ride. One rating per ride — sending again
  /// replaces the previous one rather than failing.
  Future<void> rateRide(
    String rideId, {
    required int stars,
    String? reason,
    CancelToken? cancelToken,
  }) async {
    final trimmed = reason?.trim();
    await _send(
      method: 'POST',
      uri: _backendUri('/rides/$rideId/rating'),
      body: {
        'stars': stars,
        if (trimmed != null && trimmed.isNotEmpty) 'reason': trimmed,
      },
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
  }

  /// Whether this ride already carries a rating from the rider, so the prompt
  /// is not shown again on the next visit.
  Future<bool> hasRated(String rideId, {CancelToken? cancelToken}) async {
    try {
      final json = await _send(
        method: 'GET',
        uri: _backendUri('/rides/$rideId/rating'),
        timeout: const Duration(seconds: 8),
        cancelToken: cancelToken,
      );
      if (json is! Map) return false;
      return json['rating'] != null;
    } on ApiException catch (e) {
      // A ride with no rating yet is the normal case, not a failure.
      if (e.kind == ApiErrorKind.notFound) return false;
      rethrow;
    }
  }

  Future<DriverOffer> driverOffers({CancelToken? cancelToken}) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers/me/offers'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );

    if (json is! Map) {
      return const DriverOffer(offers: []);
    }

    final list = json['offers'];
    final offers = <RideOffer>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        offers.add(RideOffer.fromJson(item.cast<String, dynamic>()));
      }
    }

    final expiredList = json['expired'];
    return DriverOffer(
      offers: offers,
      expired: expiredList is List
          ? expiredList.map((e) => e.toString()).toList(growable: false)
          : const [],
    );
  }

  // -------------------------------------------------------------------------
  // Geocoding
  // -------------------------------------------------------------------------

  /// Routes through the **backend** `/search` endpoint, which proxies to
  /// Photon and caches results in the database. Use this instead of
  /// [geocode] when the backend is live.
  Future<List<GeocodeResult>> searchPlaces({
    required String query,
    double? biasLat,
    double? biasLng,
    int limit = 8,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/search', {
        'q': query,
        'lat': biasLat,
        'lon': biasLng,
        'limit': limit,
      }),
      timeout: const Duration(seconds: 6),
      cancelToken: cancelToken,
    );

    if (json is! List) return const [];

    final results = <GeocodeResult>[];
    for (final item in json) {
      if (item is! Map) continue;
      final lat = (item['lat'] as num?)?.toDouble();
      final lng = (item['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      final label = item['label']?.toString() ?? 'Unknown place';
      final primary = item['primary']?.toString() ?? label;
      final secondary = item['secondary']?.toString() ?? '';

      results.add(GeocodeResult(
        label: label,
        primary: primary,
        secondary: secondary,
        lat: lat,
        lng: lng,
      ));
    }
    return results;
  }

  // -------------------------------------------------------------------------
  // Location
  // -------------------------------------------------------------------------

  Future<void> saveLocation({
    required double lat,
    required double lng,
    double? accuracy,
    CancelToken? cancelToken,
  }) async {
    await _send(
      method: 'POST',
      uri: _backendUri('/location'),
      body: {
        'lat': lat,
        'lng': lng,
        if (accuracy != null) 'accuracy': accuracy,
      },
      timeout: const Duration(seconds: 6),
      cancelToken: cancelToken,
    );
  }

  // -------------------------------------------------------------------------
  // Driver self-service
  // -------------------------------------------------------------------------

  /// Persists the driver's online/offline state (and their live position) on
  /// the backend. Without this the driver never shows up in `GET /drivers`,
  /// which is what riders use to find someone nearby.
  Future<bool> setDriverOnline({
    required bool isOnline,
    double? lat,
    double? lng,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/drivers/me/status'),
      body: {
        'is_online': isOnline,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      },
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map && (json['is_online'] as bool? ?? isOnline) == isOnline;
  }

  /// Full driver dashboard payload: identity, stats, cars, services.
  Future<DriverProfile?> fetchDriverProfile({CancelToken? cancelToken}) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers/me'),
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
    if (json is! Map) return null;
    return DriverProfile.fromJson(json.cast<String, dynamic>());
  }

  Future<DriverPricing?> fetchDriverPricing({
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers/me/pricing'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    if (json is! Map) return null;
    return DriverPricing.fromJson(json.cast<String, dynamic>());
  }

  /// Saves the driver's rate card. Returns the persisted pricing plus sample
  /// fares, so the UI can preview the effect of the change.
  Future<({DriverPricing pricing, Map<String, double> examples})?>
      updateDriverPricing({
    required DriverPricing pricing,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'PATCH',
      uri: _backendUri('/drivers/me/pricing'),
      body: pricing.toJson(),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    if (json is! Map) return null;

    final pricingJson = json['pricing'];
    final examplesJson = json['examples'];
    final examples = <String, double>{};
    if (examplesJson is Map) {
      examplesJson.forEach((k, v) {
        if (v is num) examples['$k'] = v.toDouble();
      });
    }
    return (
      pricing: pricingJson is Map
          ? DriverPricing.fromJson(pricingJson.cast<String, dynamic>())
          : pricing,
      examples: examples,
    );
  }

  Future<List<RideModel>> fetchDriverRides({
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers/me/rides', {'limit': limit}),
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
    if (json is! Map) return const [];
    final list = json['rides'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => RideModel.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Offer details including the rider's phone number. Used when a `ride_offer`
  /// arrives over the socket, so the driver can see who they are collecting.
  Future<RideOfferBrief?> fetchRideBrief({
    required String rideId,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/rides/$rideId/brief'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    if (json is! Map) return null;
    return RideOfferBrief.fromJson(json.cast<String, dynamic>());
  }

  // -------------------------------------------------------------------------
  // Vehicles — "manage cars"
  // -------------------------------------------------------------------------

  Future<List<VehicleInfo>> fetchDriverVehicles({
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers/me/vehicles'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    if (json is! Map) return const [];
    final list = json['vehicles'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => VehicleInfo.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<String?> createDriverVehicle({
    required VehicleInfo vehicle,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/drivers/me/vehicles'),
      body: vehicle.toJson(),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map ? json['id'] as String? : null;
  }

  Future<bool> updateDriverVehicle({
    required String vehicleId,
    required VehicleInfo vehicle,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'PATCH',
      uri: _backendUri('/drivers/me/vehicles/$vehicleId'),
      body: vehicle.toJson(),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map;
  }

  Future<bool> deleteDriverVehicle({
    required String vehicleId,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'DELETE',
      uri: _backendUri('/drivers/me/vehicles/$vehicleId'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map;
  }

  // -------------------------------------------------------------------------
  // Services
  // -------------------------------------------------------------------------

  Future<List<DriverService>> fetchDriverServices({
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers/me/services'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    if (json is! Map) return const [];
    final list = json['services'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => DriverService.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<String?> createDriverService({
    required DriverService service,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'POST',
      uri: _backendUri('/drivers/me/services'),
      body: service.toJson(),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map ? json['id'] as String? : null;
  }

  Future<bool> updateDriverService({
    required String serviceId,
    required DriverService service,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'PATCH',
      uri: _backendUri('/drivers/me/services/$serviceId'),
      body: service.toJson(),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map;
  }

  Future<bool> deleteDriverService({
    required String serviceId,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'DELETE',
      uri: _backendUri('/drivers/me/services/$serviceId'),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );
    return json is Map;
  }

  Future<List<NearbyDriver>> getNearbyDrivers({
    required double lat,
    required double lng,
    double radiusKm = 10,
    int limit = 20,
    CancelToken? cancelToken,
    double? tripDistanceMeters,
    double? tripDurationSeconds,
  }) async {
    final query = <String, String>{
      'lat': '$lat',
      'lon': '$lng',
      'radius_km': '$radiusKm',
      'limit': '$limit',
    };
    if (tripDistanceMeters != null) {
      query['trip_distance_meters'] = '$tripDistanceMeters';
      query['trip_duration_seconds'] = '${tripDurationSeconds ?? 0}';
    }

    final json = await _send(
      method: 'GET',
      uri: _backendUri('/drivers', query),
      timeout: const Duration(seconds: 8),
      cancelToken: cancelToken,
    );

    if (json is! Map) return const [];

    final driversList = json['drivers'];
    if (driversList is! List) return const [];

    final results = <NearbyDriver>[];
    for (final item in driversList) {
      if (item is! Map) continue;
      final driver = NearbyDriver.fromJson(item.cast<String, dynamic>());
      if (driver != null) results.add(driver);
    }
    return results;
  }

  Future<List<GeocodeResult>> geocode({
    required String query,
    double? biasLat,
    double? biasLng,
    int limit = 8,
    CancelToken? cancelToken,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 3) return const [];

    final isNominatim = geocoderBaseUrl.contains('nominatim');
    final uri = isNominatim
        ? Uri.parse(
            '$geocoderBaseUrl/search'
            '?q=${Uri.encodeQueryComponent(trimmed)}'
            '&format=jsonv2&limit=$limit&addressdetails=1'
            '${biasLat != null && biasLng != null ? '&viewbox=${biasLng - 1},${biasLat - 1},${biasLng + 1},${biasLat + 1}&bounded=0' : ''}',
          )
        : Uri.parse(
            '$geocoderBaseUrl/api/'
            '?q=${Uri.encodeQueryComponent(trimmed)}'
            '&limit=$limit'
            '${biasLat != null && biasLng != null ? '&lat=$biasLat&lon=$biasLng' : ''}',
          );

    final json = await _send(
      method: 'GET',
      uri: uri,
      timeout: const Duration(seconds: 6),
      cancelToken: cancelToken,
    );

    final features = isNominatim
        ? json
        : (json is Map ? json['features'] : null);

    if (features is! List) return const [];

    final results = <GeocodeResult>[];
    for (final f in features) {
      final parsed = isNominatim ? _parseNominatim(f) : _parsePhoton(f);
      if (parsed != null) results.add(parsed);
    }
    return results;
  }

  Future<GeocodeResult?> reverseGeocode({
    required double lat,
    required double lng,
    CancelToken? cancelToken,
  }) async {
    final isNominatim = geocoderBaseUrl.contains('nominatim');
    final uri = isNominatim
        ? Uri.parse(
            '$geocoderBaseUrl/reverse'
            '?lat=$lat&lon=$lng&format=jsonv2&addressdetails=1',
          )
        : Uri.parse(
            '$geocoderBaseUrl/reverse'
            '?lat=$lat&lon=$lng&limit=1',
          );

    final json = await _send(
      method: 'GET',
      uri: uri,
      timeout: const Duration(seconds: 6),
      cancelToken: cancelToken,
    );

    if (isNominatim) {
      return _parseNominatim(json);
    }

    final features = json is Map ? json['features'] : null;
    if (features is! List || features.isEmpty) return null;
    return _parsePhoton(features.first);
  }

  // -------------------------------------------------------------------------
  // Rides
  // -------------------------------------------------------------------------

  Future<List<RideHistoryItem>> getRideHistory({
    String? status,
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'GET',
      uri: _backendUri('/rides', {
        if (status != null) 'status': status,
        'limit': limit,
      }),
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );

    if (json is! List) return const [];

    final results = <RideHistoryItem>[];
    for (final item in json) {
      if (item is Map) {
        final parsed = RideHistoryItem.fromJson(
          item.cast<String, dynamic>(),
        );
        if (parsed != null) results.add(parsed);
      }
    }
    return results;
  }

  Future<UserModel> updateProfile({
    String? fullName,
    String? phone,
    String? email,
    CancelToken? cancelToken,
  }) async {
    final json = await _send(
      method: 'PATCH',
      uri: _backendUri('/auth/profile'),
      body: {
        if (fullName != null) 'full_name': fullName,
        if (phone != null) 'phone': phone,
        if (email != null) 'email': email,
      },
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );

    if (json is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Profile response is incomplete.',
      );
    }

    final userJson = json['user'];
    if (userJson is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Profile response is incomplete.',
      );
    }

    return UserModel.fromJson(userJson.cast<String, dynamic>());
  }

  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
    CancelToken? cancelToken,
  }) async {
    await _send(
      method: 'PATCH',
      uri: _backendUri('/auth/password'),
      body: {
        'current_password': currentPassword,
        'new_password': newPassword,
      },
      timeout: const Duration(seconds: 10),
      cancelToken: cancelToken,
    );
  }

  // =========================================================================
  // INTERNALS
  // =========================================================================

  Uri _backendUri(String path, [Map<String, dynamic>? query]) {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    final base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');
    final uri = base.resolve(normalized);
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        for (final e in query.entries)
          if (e.value != null) e.key: e.value.toString(),
      },
    );
  }

  Future<dynamic> _send({
    required String method,
    required Uri uri,
    Object? body,
    Duration? timeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
  }) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final mergedHeaders = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json; charset=utf-8',
      'User-Agent': 'FastRide/1.0 (Flutter)',
      ...defaultHeaders,
      if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      ...?headers,
    };

    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiException(
          kind: ApiErrorKind.cancelled,
          message: 'Request cancelled.',
        );
      }

      final stopwatch = Stopwatch()..start();
      http.Response? response;
      try {
        final request = http.Request(method, uri)
          ..headers.addAll(mergedHeaders);
        if (body != null) {
          request.body = body is String ? body : jsonEncode(body);
        }

        final streamed = await _http.send(request).timeout(effectiveTimeout);
        response = await http.Response.fromStream(
          streamed,
        ).timeout(effectiveTimeout);
        stopwatch.stop();

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return _decode(response.body);
        }

        final code = response.statusCode;
        final retryable = code == 408 || code == 429 || code >= 500;

        final err = _httpErrorFrom(response);

        if (!retryable || attempt == maxRetries) {
          throw err;
        }
        lastError = err;
      } on TimeoutException catch (e, s) {
        stopwatch.stop();
        lastError = ApiException(
          kind: ApiErrorKind.timeout,
          message:
              'The request timed out after ${effectiveTimeout.inSeconds}s.',
          cause: e,
        );
        lastStack = s;
        if (attempt == maxRetries) throw lastError;
      } on SocketException catch (e, s) {
        stopwatch.stop();
        lastError = ApiException(
          kind: ApiErrorKind.network,
          message: 'No internet connection. Please check your network.',
          cause: e,
        );
        lastStack = s;
        if (attempt == maxRetries) throw lastError;
      } on http.ClientException catch (e, s) {
        stopwatch.stop();
        lastError = ApiException(
          kind: ApiErrorKind.network,
          message: 'Connection failed. Please try again.',
          cause: e,
        );
        lastStack = s;
        if (attempt == maxRetries) throw lastError;
      } on ApiException {
        rethrow;
      } catch (e, s) {
        stopwatch.stop();
        lastError = ApiException(
          kind: ApiErrorKind.unknown,
          message: 'Something went wrong. Please try again.',
          cause: e,
        );
        lastStack = s;
        if (attempt == maxRetries) throw lastError;
      }

      final base = 300 * math.pow(2, attempt).toInt();
      final jitter = math.Random().nextInt(200);
      final delay = math.min(base + jitter, 4000);
      await Future<void>.delayed(Duration(milliseconds: delay));
    }

    throw ApiException(
      kind: ApiErrorKind.unknown,
      message: 'Request failed after $maxRetries retries.',
      cause: lastError,
      stackTrace: lastStack,
    );
  }

  dynamic _decode(String raw) {
    if (raw.isEmpty) return null;
    final trimmed = raw.trimLeft();
    final cleaned = trimmed.startsWith(")]}'")
        ? trimmed.split('\n').skip(1).join('\n')
        : raw;
    try {
      return jsonDecode(cleaned);
    } on FormatException catch (e) {
      throw ApiException(
        kind: ApiErrorKind.badData,
        message: 'The server returned an unexpected response.',
        cause: e,
      );
    }
  }

  ApiException _httpErrorFrom(http.Response response) {
    final code = response.statusCode;
    String message;
    switch (code) {
      case 400:
        message = 'Invalid request.';
        break;
      case 401:
        message = 'Session expired. Please sign in again.';
        break;
      case 403:
        message = 'You do not have access to this action.';
        break;
      case 404:
        message = 'The requested resource was not found.';
        break;
      case 409:
        message = 'This action conflicts with the current state.';
        break;
      case 422:
        message = 'Please review the information and try again.';
        break;
      case 429:
        message = 'Too many requests. Please slow down.';
        break;
      case 500:
      case 502:
      case 503:
      case 504:
        message = 'Our servers are busy. Please try again shortly.';
        break;
      default:
        message = 'Unexpected server response ($code).';
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final serverMessage =
            decoded['detail'] is String
                ? decoded['detail'] as String
                : decoded['message'] is String
                ? decoded['message'] as String
                : null;
        if (serverMessage != null && serverMessage.isNotEmpty) {
          message = serverMessage;
        }
      }
    } catch (_) {}

    return ApiException(
      kind: switch (code) {
        401 || 403 => ApiErrorKind.unauthorized,
        404 => ApiErrorKind.notFound,
        408 || 504 => ApiErrorKind.timeout,
        429 => ApiErrorKind.rateLimited,
        >= 500 => ApiErrorKind.server,
        _ => ApiErrorKind.client,
      },
      statusCode: code,
      message: message,
    );
  }

  GeocodeResult? _parsePhoton(dynamic feature) {
    if (feature is! Map) return null;
    final geometry = feature['geometry'];
    final properties = feature['properties'];
    if (geometry is! Map || properties is! Map) return null;

    final coords = geometry['coordinates'];
    if (coords is! List || coords.length < 2) return null;

    final lng = (coords[0] as num?)?.toDouble();
    final lat = (coords[1] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final primary =
        _firstNonEmpty([
          properties['name'],
          properties['street'],
          properties['city'],
        ]) ??
        'Unknown place';

    final secondaryParts = <String>[
      properties['street'],
      properties['city'],
      properties['state'],
      properties['country'],
    ].whereType<String>().where((s) => s.isNotEmpty).toSet().toList();

    final label = secondaryParts.isEmpty
        ? primary
        : '$primary · ${secondaryParts.take(3).join(', ')}';

    return GeocodeResult(
      label: label,
      primary: primary,
      secondary: secondaryParts.join(', '),
      lat: lat,
      lng: lng,
    );
  }

  GeocodeResult? _parseNominatim(dynamic item) {
    if (item is! Map) return null;
    final lat = double.tryParse(item['lat']?.toString() ?? '');
    final lng = double.tryParse(item['lon']?.toString() ?? '');
    if (lat == null || lng == null) return null;

    final displayName = item['display_name']?.toString();
    final name = item['name']?.toString();
    final address = item['address'];

    final primary =
        _firstNonEmpty([name, displayName?.split(',').first]) ??
        'Unknown place';

    String secondary = '';
    if (address is Map) {
      final parts = <String>[
        address['road'],
        address['suburb'],
        address['city'] ?? address['town'] ?? address['village'],
        address['state'],
        address['country'],
      ].whereType<String>().where((s) => s.isNotEmpty).toList();
      secondary = parts.join(', ');
    } else if (displayName != null) {
      final commaIdx = displayName.indexOf(',');
      secondary = commaIdx > 0
          ? displayName.substring(commaIdx + 1).trim()
          : '';
    }

    return GeocodeResult(
      label: secondary.isEmpty ? primary : '$primary · $secondary',
      primary: primary,
      secondary: secondary,
      lat: lat,
      lng: lng,
    );
  }

  String? _firstNonEmpty(List<dynamic> values) {
    for (final v in values) {
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  void dispose() {
    _http.close();
  }
}

class RideHistoryItem {
  const RideHistoryItem({
    required this.id,
    required this.state,
    this.fareEstimate,
    this.fareFinal,
    this.currency = 'KES',
    this.distanceMeters,
    this.durationSeconds,
    this.pickupPlace,
    this.dropoffPlace,
    this.requestedAt,
    this.completedAt,
    this.cancelledAt,
    this.driverName,
    this.driverRating,
  });

  final String id;
  final String state;
  final double? fareEstimate;
  final double? fareFinal;
  final String currency;
  final double? distanceMeters;
  final double? durationSeconds;
  final String? pickupPlace;
  final String? dropoffPlace;
  final DateTime? requestedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? driverName;
  final double? driverRating;

  String get displayFare {
    final value = fareFinal ?? fareEstimate;
    if (value == null) return '—';
    final symbol = CurrencySymbols.of(currency);
    return '$symbol${value.toStringAsFixed(0)}';
  }

  String get displayDistance {
    final m = distanceMeters;
    if (m == null) return '—';
    if (m < 1000) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  String get displayDuration {
    final s = durationSeconds;
    if (s == null) return '—';
    final m = (s / 60).round();
    if (m < 1) return '<1 min';
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return '${h}h ${r.toString().padLeft(2, '0')}m';
  }

  String get stateLabel {
    switch (state) {
      case 'completed':
        return 'Completed';
      case 'cancelled':
        return 'Cancelled';
      case 'accepted':
        return 'Driver assigned';
      case 'ongoing':
        return 'On trip';
      case 'matching':
        return 'Matching';
      case 'requested':
        return 'Finding driver';
      case 'driver_arriving':
        return 'Driver arriving';
      case 'driver_arrived':
        return 'Driver arrived';
      default:
        return state;
    }
  }

  static RideHistoryItem? fromJson(Map<String, dynamic> json) {
    return RideHistoryItem(
      id: json['id']?.toString() ?? '',
      state: json['state']?.toString() ?? 'unknown',
      fareEstimate:
          (json['fare_estimate'] as num?)?.toDouble(),
      fareFinal:
          (json['fare_final'] as num?)?.toDouble(),
      currency: json['currency']?.toString() ?? 'KES',
      distanceMeters:
          (json['distance_meters'] as num?)?.toDouble(),
      durationSeconds:
          (json['duration_seconds'] as num?)?.toDouble(),
      pickupPlace: json['pickup_place']?.toString(),
      dropoffPlace: json['dropoff_place']?.toString(),
      requestedAt: _parseDate(json['requested_at']),
      completedAt: _parseDate(json['completed_at']),
      cancelledAt: _parseDate(json['cancelled_at']),
      driverName: json['driver_name']?.toString(),
      driverRating: (json['driver_rating'] as num?)?.toDouble(),
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    if (value is int) {
      if (value > 100000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    return null;
  }
}

// =========================================================================
// Support types
// =========================================================================

@immutable
class OsrmRoute {
  const OsrmRoute({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polyline,
    this.segments = const [],
  });

  final double distanceMeters;
  final double durationSeconds;
  final List<({double lat, double lng})> polyline;
  final List<RouteSegment> segments;
}

@immutable
class GeocodeResult {
  const GeocodeResult({
    required this.label,
    required this.primary,
    required this.secondary,
    required this.lat,
    required this.lng,
  });

  final String label;
  final String primary;
  final String secondary;
  final double lat;
  final double lng;

  LatLng get coords => LatLng(lat, lng);
}

/// The rider's live position while the driver is on the way to pickup.
@immutable
class RiderLocation {
  const RiderLocation({
    required this.riderId,
    required this.state,
    required this.pickup,
    this.liveLat,
    this.liveLng,
    this.accuracy,
    this.ageSeconds,
  });

  final String riderId;
  final String state;
  final RideLocation pickup;

  /// The rider's most recent fix. Null until one lands, or once it goes stale.
  final double? liveLat;
  final double? liveLng;
  final double? accuracy;
  final double? ageSeconds;

  /// True while the rider's position is being reported and still fresh.
  bool get hasLiveFix => liveLat != null && liveLng != null;

  /// Where to put the rider's pin: their live position when we have one,
  /// otherwise the point the ride was booked against.
  LatLng get marker => hasLiveFix
      ? LatLng(liveLat!, liveLng!)
      : LatLng(pickup.lat, pickup.lng);

  static RiderLocation fromJson(Map<String, dynamic> json) {
    final pickupJson = json['pickup'];
    final pickup = pickupJson is Map
        ? RideLocation.fromJson(pickupJson.cast<String, dynamic>())
        : const RideLocation(lat: 0, lng: 0);

    final live = json['live'];
    final m = live is Map ? live.cast<String, dynamic>() : null;

    return RiderLocation(
      riderId: json['rider_id']?.toString() ?? '',
      state: json['state']?.toString() ?? 'requested',
      pickup: pickup,
      liveLat: (m?['lat'] as num?)?.toDouble(),
      liveLng: (m?['lng'] as num?)?.toDouble(),
      accuracy: (m?['accuracy'] as num?)?.toDouble(),
      ageSeconds: (m?['age_seconds'] as num?)?.toDouble(),
    );
  }
}

@immutable
class NearbyDriver {
  const NearbyDriver({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.rating,
    required this.totalTrips,
    required this.isVerified,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
    this.vehicle,
    this.lastSeenAt,
    this.pricing = const DriverPricing(),
    this.fareEstimate,
    this.fareBreakdown,
  });

  final String id;
  final String fullName;
  final String phone;
  final double rating;
  final int totalTrips;
  final bool isVerified;
  final double latitude;
  final double longitude;
  final double distanceMeters;
  final VehicleInfo? vehicle;
  final DateTime? lastSeenAt;

  /// The driver's own rate card, as returned by `GET /drivers`.
  final DriverPricing pricing;

  /// Server-quoted fare for the trip being priced, when a trip was supplied.
  final double? fareEstimate;
  final FareBreakdown? fareBreakdown;

  LatLng get coords => LatLng(latitude, longitude);
  bool get isOnline => true;

  /// Falls back to a client-side quote when the server did not price the trip.
  double quoteFor({
    required double distanceMeters,
    required double durationSeconds,
  }) {
    if (fareEstimate != null) return fareEstimate!;
    return pricing.quote(
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
    );
  }

  static NearbyDriver? fromJson(Map<String, dynamic> json) {
    final lat = (json['latitude'] as num?)?.toDouble();
    final lng = (json['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final vehicleJson = json['vehicle'];
    VehicleInfo? vehicle;
    if (vehicleJson is Map) {
      final casted = vehicleJson.cast<String, dynamic>();
      final make = casted['make']?.toString() ?? '';
      final model = casted['model']?.toString() ?? '';
      final plate = casted['plate_number']?.toString() ?? '';
      if (make.isNotEmpty || model.isNotEmpty || plate.isNotEmpty) {
        vehicle = VehicleInfo(
          make: make,
          model: model,
          plateNumber: plate,
          color: casted['color']?.toString(),
          year: (casted['year'] as num?)?.toInt(),
          vehicleClass: VehicleClassX.fromString(
            casted['vehicle_class']?.toString() ??
                casted['class']?.toString(),
          ),
          seats: (casted['seats'] as num?)?.toInt() ?? 4,
          photoUrl: casted['photo_url']?.toString() ??
              casted['image']?.toString(),
        );
      }
    }

    return NearbyDriver(
      id: json['id']?.toString() ?? '',
      fullName: json['full_name']?.toString() ??
          json['name']?.toString() ??
          '',
      phone: json['phone']?.toString() ?? '',
      rating: (json['rating'] as num?)?.toDouble() ?? 5.0,
      totalTrips: (json['total_trips'] as num?)?.toInt() ?? 0,
      isVerified: json['is_verified'] as bool? ?? false,
      latitude: lat,
      longitude: lng,
      distanceMeters: (json['distance_meters'] as num?)?.toDouble() ?? 0,
      vehicle: vehicle,
      pricing: _pricingFrom(json['pricing']),
      fareEstimate: (json['fare_estimate'] as num?)?.toDouble(),
      fareBreakdown: json['fare_breakdown'] is Map
          ? FareBreakdown.fromJson(
              (json['fare_breakdown'] as Map).cast<String, dynamic>())
          : null,
      lastSeenAt: _parseDate(json['last_seen_at'] ?? json['lastSeenAt']),
    );
  }

  static DriverPricing _pricingFrom(dynamic value) {
    if (value is! Map) return const DriverPricing();
    final m = value.cast<String, dynamic>();
    return DriverPricing(
      baseFare: (m['base_fare'] as num?)?.toDouble() ?? 50,
      pricePerKm: (m['price_per_km'] as num?)?.toDouble() ?? 25,
      pricePerMinute: (m['price_per_minute'] as num?)?.toDouble() ?? 3,
      minimumFare: (m['minimum_fare'] as num?)?.toDouble() ?? 100,
      currency: m['currency']?.toString() ?? 'KES',
    );
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) {
      return DateTime.tryParse(value);
    }
    if (value is int) {
      if (value > 100000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    return null;
  }
}

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

@immutable
class RouteSegment {
  const RouteSegment({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.avgSpeedKmh,
    required this.polyline,
    this.maneuver,
  });

  final double distanceMeters;
  final double durationSeconds;
  final double avgSpeedKmh;
  final List<({double lat, double lng})> polyline;
  final String? maneuver;

  static RouteSegment? fromJson(Map<String, dynamic> json) {
    final distance = (json['distance_meters'] as num?)?.toDouble();
    final duration = (json['duration_seconds'] as num?)?.toDouble();
    if (distance == null || duration == null) return null;

    final avgSpeed = (json['avg_speed_kmh'] as num?)?.toDouble() ?? 0;
    final coordsList = json['polyline'];
    final points = <({double lat, double lng})>[];
    if (coordsList is List) {
      for (final c in coordsList) {
        if (c is Map) {
          final lat = (c['lat'] as num?)?.toDouble();
          final lng = (c['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) {
            points.add((lat: lat, lng: lng));
          }
        }
      }
    }

    return RouteSegment(
      distanceMeters: distance,
      durationSeconds: duration,
      avgSpeedKmh: avgSpeed,
      polyline: points,
      maneuver: json['maneuver']?.toString(),
    );
  }
}

enum ApiErrorKind {
  network,
  timeout,
  cancelled,
  unauthorized,
  notFound,
  client,
  server,
  rateLimited,
  badData,
  unknown,
}

class ApiException implements Exception {
  const ApiException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.cause,
    this.stackTrace,
  });

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;
  final Object? cause;
  final StackTrace? stackTrace;

  bool get isRetryable =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.server ||
      kind == ApiErrorKind.rateLimited;

  @override
  String toString() =>
      'ApiException($kind${statusCode != null ? ' $statusCode' : ''}): $message';
}
