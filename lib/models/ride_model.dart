import 'package:flutter/foundation.dart';

import 'driver_model.dart';
import 'user_model.dart';

@immutable
class RideModel {
  const RideModel({
    required this.id,
    required this.riderId,
    required this.state,
    required this.pickup,
    required this.dropoff,
    this.driverId,
    this.driver,
    this.rider,
    this.vehicleClass = VehicleClass.standard,
    this.fareEstimate,
    this.fareFinal,
    this.currency = 'KES',
    this.distanceMeters,
    this.durationSeconds,
    this.polyline = const [],
    this.requestedAt,
    this.acceptedAt,
    this.arrivedAtPickupAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancellationReason,
    this.otp,
  });

  final String id;
  final String riderId;
  final RideState state;
  final RideLocation pickup;
  final RideLocation dropoff;
  final String? driverId;
  final DriverModel? driver;
  final UserModel? rider;
  final VehicleClass vehicleClass;
  final double? fareEstimate;
  final double? fareFinal;
  final String currency;
  final double? distanceMeters;
  final double? durationSeconds;
  final List<({double lat, double lng})> polyline;
  final DateTime? requestedAt;
  final DateTime? acceptedAt;
  final DateTime? arrivedAtPickupAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? cancellationReason;
  final String? otp;

  double? get displayFare => fareFinal ?? fareEstimate;

  String get fareLabel {
    final value = displayFare;
    if (value == null) return '—';
    final symbol = CurrencySymbols.of(currency);
    return '$symbol${value.toStringAsFixed(2)}';
  }

  String get distanceLabel {
    final meters = distanceMeters;
    if (meters == null) return '—';
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String get durationLabel {
    final seconds = durationSeconds;
    if (seconds == null) return '—';
    final total = seconds.round();
    if (total < 60) return '${total}s';
    final minutes = total ~/ 60;
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return '${hours}h ${rem.toString().padLeft(2, '0')}m';
  }

  bool get isTerminal =>
      state == RideState.completed ||
      state == RideState.cancelled ||
      state == RideState.expired;

  bool get isActive =>
      state == RideState.accepted ||
      state == RideState.driverArriving ||
      state == RideState.driverArrived ||
      state == RideState.ongoing;

  bool get isCancellable =>
      state == RideState.requested ||
      state == RideState.matching ||
      state == RideState.accepted ||
      state == RideState.driverArriving;

  Duration? elapsedSinceState() {
    final anchor = switch (state) {
      RideState.requested || RideState.matching => requestedAt,
      RideState.accepted => acceptedAt,
      RideState.driverArriving => acceptedAt,
      RideState.driverArrived => arrivedAtPickupAt,
      RideState.ongoing => startedAt,
      RideState.completed => completedAt,
      RideState.cancelled => cancelledAt,
      RideState.expired => cancelledAt,
      RideState.draft => null,
    };
    if (anchor == null) return null;
    return DateTime.now().difference(anchor);
  }

  RideModel copyWith({
    String? id,
    String? riderId,
    RideState? state,
    RideLocation? pickup,
    RideLocation? dropoff,
    Object? driverId = _sentinel,
    Object? driver = _sentinel,
    Object? rider = _sentinel,
    VehicleClass? vehicleClass,
    Object? fareEstimate = _sentinel,
    Object? fareFinal = _sentinel,
    String? currency,
    Object? distanceMeters = _sentinel,
    Object? durationSeconds = _sentinel,
    List<({double lat, double lng})>? polyline,
    Object? requestedAt = _sentinel,
    Object? acceptedAt = _sentinel,
    Object? arrivedAtPickupAt = _sentinel,
    Object? startedAt = _sentinel,
    Object? completedAt = _sentinel,
    Object? cancelledAt = _sentinel,
    Object? cancellationReason = _sentinel,
    Object? otp = _sentinel,
  }) {
    return RideModel(
      id: id ?? this.id,
      riderId: riderId ?? this.riderId,
      state: state ?? this.state,
      pickup: pickup ?? this.pickup,
      dropoff: dropoff ?? this.dropoff,
      driverId: driverId == _sentinel ? this.driverId : driverId as String?,
      driver: driver == _sentinel ? this.driver : driver as DriverModel?,
      rider: rider == _sentinel ? this.rider : rider as UserModel?,
      vehicleClass: vehicleClass ?? this.vehicleClass,
      fareEstimate: fareEstimate == _sentinel
          ? this.fareEstimate
          : fareEstimate as double?,
      fareFinal:
          fareFinal == _sentinel ? this.fareFinal : fareFinal as double?,
      currency: currency ?? this.currency,
      distanceMeters: distanceMeters == _sentinel
          ? this.distanceMeters
          : distanceMeters as double?,
      durationSeconds: durationSeconds == _sentinel
          ? this.durationSeconds
          : durationSeconds as double?,
      polyline: polyline ?? this.polyline,
      requestedAt:
          requestedAt == _sentinel ? this.requestedAt : requestedAt as DateTime?,
      acceptedAt:
          acceptedAt == _sentinel ? this.acceptedAt : acceptedAt as DateTime?,
      arrivedAtPickupAt: arrivedAtPickupAt == _sentinel
          ? this.arrivedAtPickupAt
          : arrivedAtPickupAt as DateTime?,
      startedAt:
          startedAt == _sentinel ? this.startedAt : startedAt as DateTime?,
      completedAt:
          completedAt == _sentinel ? this.completedAt : completedAt as DateTime?,
      cancelledAt:
          cancelledAt == _sentinel ? this.cancelledAt : cancelledAt as DateTime?,
      cancellationReason: cancellationReason == _sentinel
          ? this.cancellationReason
          : cancellationReason as String?,
      otp: otp == _sentinel ? this.otp : otp as String?,
    );
  }

  factory RideModel.fromJson(Map<String, dynamic> json) {
    final driverJson = json['driver'];
    final riderJson = json['rider'];

    return RideModel(
      id: _string(json['id']) ?? _string(json['ride_id']) ?? '',
      riderId: _string(json['rider_id']) ?? _string(json['user_id']) ?? '',
      state: RideStateX.fromString(
        _string(json['state']) ?? _string(json['status']),
      ),
      pickup: RideLocation.fromJson(
        _map(json['pickup']) ?? _map(json['pickup_location']) ?? const {},
      ),
      dropoff: RideLocation.fromJson(
        _map(json['dropoff']) ?? _map(json['dropoff_location']) ?? const {},
      ),
      driverId: _string(json['driver_id']),
      driver: driverJson is Map
          ? DriverModel.fromJson(driverJson.cast<String, dynamic>())
          : null,
      rider: riderJson is Map
          ? UserModel.fromJson(riderJson.cast<String, dynamic>())
          : null,
      vehicleClass: VehicleClassX.fromString(
        _string(json['vehicle_class']) ?? _string(json['class']),
      ),
      fareEstimate: _double(json['fare_estimate']) ??
          _double(json['estimated_fare']) ??
          _double(json['fare']),
      fareFinal: _double(json['fare_final']) ??
          _double(json['final_fare']) ??
          _double(json['total']),
      currency: _string(json['currency']) ?? 'USD',
      distanceMeters:
          _double(json['distance_meters']) ?? _double(json['distance']),
      durationSeconds:
          _double(json['duration_seconds']) ?? _double(json['duration']),
      polyline: _polyline(json['polyline']) ??
          _polyline(json['route']) ??
          const <({double lat, double lng})>[],
      requestedAt: _date(json['requested_at']) ?? _date(json['created_at']),
      acceptedAt: _date(json['accepted_at']),
      arrivedAtPickupAt:
          _date(json['arrived_at_pickup_at']) ?? _date(json['arrived_at']),
      startedAt: _date(json['started_at']),
      completedAt: _date(json['completed_at']),
      cancelledAt: _date(json['cancelled_at']),
      cancellationReason: _string(json['cancellation_reason']) ??
          _string(json['cancel_reason']),
      otp: _string(json['otp']) ?? _string(json['pickup_code']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'rider_id': riderId,
        'state': state.wire,
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        if (driverId != null) 'driver_id': driverId,
        if (driver != null) 'driver': driver!.toJson(),
        if (rider != null) 'rider': rider!.toJson(),
        'vehicle_class': vehicleClass.wire,
        if (fareEstimate != null) 'fare_estimate': fareEstimate,
        if (fareFinal != null) 'fare_final': fareFinal,
        'currency': currency,
        if (distanceMeters != null) 'distance_meters': distanceMeters,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
        if (polyline.isNotEmpty)
          'polyline':
              polyline.map((p) => {'lat': p.lat, 'lng': p.lng}).toList(),
        if (requestedAt != null) 'requested_at': requestedAt!.toIso8601String(),
        if (acceptedAt != null) 'accepted_at': acceptedAt!.toIso8601String(),
        if (arrivedAtPickupAt != null)
          'arrived_at_pickup_at': arrivedAtPickupAt!.toIso8601String(),
        if (startedAt != null) 'started_at': startedAt!.toIso8601String(),
        if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
        if (cancelledAt != null) 'cancelled_at': cancelledAt!.toIso8601String(),
        if (cancellationReason != null)
          'cancellation_reason': cancellationReason,
        if (otp != null) 'otp': otp,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RideModel &&
        other.id == id &&
        other.riderId == riderId &&
        other.state == state &&
        other.pickup == pickup &&
        other.dropoff == dropoff &&
        other.driverId == driverId &&
        other.driver == driver &&
        other.rider == rider &&
        other.vehicleClass == vehicleClass &&
        other.fareEstimate == fareEstimate &&
        other.fareFinal == fareFinal &&
        other.currency == currency &&
        other.distanceMeters == distanceMeters &&
        other.durationSeconds == durationSeconds &&
        listEquals(other.polyline, polyline) &&
        other.requestedAt == requestedAt &&
        other.acceptedAt == acceptedAt &&
        other.arrivedAtPickupAt == arrivedAtPickupAt &&
        other.startedAt == startedAt &&
        other.completedAt == completedAt &&
        other.cancelledAt == cancelledAt &&
        other.cancellationReason == cancellationReason &&
        other.otp == otp;
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        riderId,
        state,
        pickup,
        dropoff,
        driverId,
        driver,
        rider,
        vehicleClass,
        fareEstimate,
        fareFinal,
        currency,
        distanceMeters,
        durationSeconds,
        Object.hashAll(polyline),
        requestedAt,
        acceptedAt,
        arrivedAtPickupAt,
        startedAt,
        completedAt,
        cancelledAt,
        cancellationReason,
        otp,
      ]);

  @override
  String toString() =>
      'RideModel(id: $id, state: ${state.wire}, '
      'pickup: $pickup, dropoff: $dropoff)';
}

enum RideState {
  draft,
  requested,
  matching,
  accepted,
  driverArriving,
  driverArrived,
  ongoing,
  completed,
  cancelled,
  expired,
}

extension RideStateX on RideState {
  String get wire => switch (this) {
        RideState.draft => 'draft',
        RideState.requested => 'requested',
        RideState.matching => 'matching',
        RideState.accepted => 'accepted',
        RideState.driverArriving => 'driver_arriving',
        RideState.driverArrived => 'driver_arrived',
        RideState.ongoing => 'ongoing',
        RideState.completed => 'completed',
        RideState.cancelled => 'cancelled',
        RideState.expired => 'expired',
      };

  String get label => switch (this) {
        RideState.draft => 'Draft',
        RideState.requested => 'Finding a driver',
        RideState.matching => 'Finding a driver',
        RideState.accepted => 'Driver assigned',
        RideState.driverArriving => 'Driver on the way',
        RideState.driverArrived => 'Driver has arrived',
        RideState.ongoing => 'On the trip',
        RideState.completed => 'Completed',
        RideState.cancelled => 'Cancelled',
        RideState.expired => 'No drivers found',
      };

  String get description => switch (this) {
        RideState.draft => 'Enter your destination to continue.',
        RideState.requested => 'Searching nearby drivers for you…',
        RideState.matching => 'Matching you with the closest driver…',
        RideState.accepted => 'Your driver is preparing to leave.',
        RideState.driverArriving => 'Your driver is on the way to pick you up.',
        RideState.driverArrived => 'Your driver is waiting at the pickup point.',
        RideState.ongoing => 'Enjoy your ride. Track progress live on the map.',
        RideState.completed => 'You have arrived. Thanks for riding with us!',
        RideState.cancelled => 'This ride was cancelled.',
        RideState.expired => 'We could not find a driver in time.',
      };

  bool get isDriverInbound =>
      this == RideState.accepted ||
      this == RideState.driverArriving ||
      this == RideState.driverArrived;

  bool get isTerminal =>
      this == RideState.completed ||
      this == RideState.cancelled ||
      this == RideState.expired;

  static RideState fromString(String? raw) {
    switch ((raw ?? '').toLowerCase().trim()) {
      case 'draft':
        return RideState.draft;
      case 'requested':
      case 'searching':
      case 'pending':
        return RideState.requested;
      case 'matching':
        return RideState.matching;
      case 'accepted':
      case 'assigned':
        return RideState.accepted;
      case 'driver_arriving':
      case 'arriving':
      case 'en_route':
      case 'on_the_way':
        return RideState.driverArriving;
      case 'driver_arrived':
      case 'arrived':
      case 'at_pickup':
        return RideState.driverArrived;
      case 'ongoing':
      case 'in_progress':
      case 'started':
      case 'on_trip':
        return RideState.ongoing;
      case 'completed':
      case 'finished':
      case 'done':
        return RideState.completed;
      case 'cancelled':
      case 'canceled':
        return RideState.cancelled;
      case 'expired':
      case 'timed_out':
      case 'no_drivers':
        return RideState.expired;
      default:
        return RideState.draft;
    }
  }
}

@immutable
class RideLocation {
  const RideLocation({
    required this.lat,
    required this.lng,
    this.address = '',
    this.placeName = '',
  });

  final double lat;
  final double lng;
  final String address;
  final String placeName;

  String get displayLabel {
    if (placeName.isNotEmpty) return placeName;
    if (address.isNotEmpty) {
      final commaIdx = address.indexOf(',');
      return commaIdx > 0 ? address.substring(0, commaIdx) : address;
    }
    return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  String get displaySubtitle {
    if (placeName.isNotEmpty && address.isNotEmpty) return address;
    if (address.isNotEmpty) return address;
    return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }

  RideLocation copyWith({
    double? lat,
    double? lng,
    String? address,
    String? placeName,
  }) {
    return RideLocation(
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      address: address ?? this.address,
      placeName: placeName ?? this.placeName,
    );
  }

  factory RideLocation.fromJson(Map<String, dynamic> json) {
    return RideLocation(
      lat: _double(json['lat']) ?? _double(json['latitude']) ?? 0.0,
      lng: _double(json['lng']) ??
          _double(json['lon']) ??
          _double(json['longitude']) ??
          0.0,
      address: _string(json['address']) ?? '',
      placeName: _string(json['place_name']) ??
          _string(json['name']) ??
          _string(json['label']) ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        if (address.isNotEmpty) 'address': address,
        if (placeName.isNotEmpty) 'place_name': placeName,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RideLocation &&
        other.lat == lat &&
        other.lng == lng &&
        other.address == address &&
        other.placeName == placeName;
  }

  @override
  int get hashCode => Object.hash(lat, lng, address, placeName);

  @override
  String toString() => 'RideLocation($lat, $lng, "$displayLabel")';
}

abstract final class FareCalculator {
  static const double basePrice = 50.0;
  static const double perKmRate = 25.0;
  static const double perMinuteRate = 3.0;
  static const double minimumFare = 100.0;

  static double calculate({
    required double distanceMeters,
    required double durationSeconds,
    VehicleClass vehicleClass = VehicleClass.standard,
  }) {
    final km = distanceMeters / 1000.0;
    final minutes = durationSeconds / 60.0;
    final raw = basePrice + (km * perKmRate) + (minutes * perMinuteRate);
    final withClass = raw * vehicleClass.fareMultiplier;
    return withClass < minimumFare ? minimumFare : withClass;
  }
}

abstract final class CurrencySymbols {
  static const Map<String, String> _map = {
    'USD': r'$',
    'EUR': '€',
    'GBP': '£',
    'KES': 'KSh ',
    'NGN': '₦',
    'ZAR': 'R',
    'GHS': 'GH₵',
    'UGX': 'USh ',
    'TZS': 'TSh ',
    'INR': '₹',
    'AED': 'د.إ ',
    'SAR': '﷼ ',
    'BRL': r'R$',
    'MXN': r'MX$',
    'PHP': '₱',
    'IDR': 'Rp ',
    'MYR': 'RM ',
    'SGD': r'S$',
    'JPY': '¥',
    'CNY': '¥',
    'AUD': r'A$',
    'CAD': r'C$',
  };

  static String of(String code) => _map[code.toUpperCase()] ?? '$code ';
}

const Object _sentinel = Object();

String? _string(dynamic v) {
  if (v == null) return null;
  if (v is String) {
    final trimmed = v.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return v.toString();
}

Map<String, dynamic>? _map(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return null;
}

double? _double(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

DateTime? _date(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is int) {
    if (v > 100000000000) return DateTime.fromMillisecondsSinceEpoch(v);
    return DateTime.fromMillisecondsSinceEpoch(v * 1000);
  }
  if (v is String) {
    final parsed = DateTime.tryParse(v);
    if (parsed != null) return parsed;
    final asInt = int.tryParse(v);
    if (asInt != null) return _date(asInt);
  }
  return null;
}

List<({double lat, double lng})>? _polyline(dynamic v) {
  if (v is! List || v.isEmpty) return null;
  final out = <({double lat, double lng})>[];
  for (final item in v) {
    if (item is Map) {
      final lat = _double(item['lat']) ?? _double(item['latitude']);
      final lng = _double(item['lng']) ??
          _double(item['lon']) ??
          _double(item['longitude']);
      if (lat != null && lng != null) out.add((lat: lat, lng: lng));
    } else if (item is List && item.length >= 2) {
      final a = _double(item[0]);
      final b = _double(item[1]);
      if (a != null && b != null) {
        if (a.abs() > 90 && b.abs() <= 90) {
          out.add((lat: b, lng: a));
        } else {
          out.add((lat: a, lng: b));
        }
      }
    }
  }
  return out.isEmpty ? null : out;
}