import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

// Re-export LatLng so consumers can import it from this file too.
export 'package:latlong2/latlong.dart' show LatLng;

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

  // -------------------------------------------------------------------------
  // Geocoding
  // -------------------------------------------------------------------------

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
      if (decoded is Map && decoded['message'] is String) {
        final serverMessage = decoded['message'] as String;
        if (serverMessage.isNotEmpty) message = serverMessage;
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

// =========================================================================
// Support types
// =========================================================================

@immutable
class OsrmRoute {
  const OsrmRoute({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.polyline,
  });

  final double distanceMeters;
  final double durationSeconds;
  final List<({double lat, double lng})> polyline;
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

class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
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
