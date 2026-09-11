import 'package:flutter/foundation.dart';

import 'user_model.dart';

@immutable
class DriverModel {
  const DriverModel({
    required this.id,
    required this.fullName,
    required this.phone,
    this.avatarUrl,
    this.rating = 5.0,
    this.totalTrips = 0,
    this.vehicle,
    this.isOnline = false,
    this.isVerified = false,
    this.latitude,
    this.longitude,
    this.headingDegrees,
    this.lastSeenAt,
    this.locale = 'en',
  });

  final String id;
  final String fullName;
  final String phone;
  final String? avatarUrl;
  final double rating;
  final int totalTrips;
  final VehicleInfo? vehicle;
  final bool isOnline;
  final bool isVerified;
  final double? latitude;
  final double? longitude;
  final double? headingDegrees;
  final DateTime? lastSeenAt;
  final String locale;

  String get initials {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }

  String get firstName {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return 'Driver';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  String get ratingLabel => rating.toStringAsFixed(1);

  String get tripsLabel {
    if (totalTrips >= 1000) {
      final k = (totalTrips / 1000).toStringAsFixed(1);
      return '${k}k trips';
    }
    return '$totalTrips ${totalTrips == 1 ? 'trip' : 'trips'}';
  }

  bool get hasPosition => latitude != null && longitude != null;

  bool isFresh({Duration staleAfter = const Duration(minutes: 2)}) {
    final seen = lastSeenAt;
    if (seen == null) return false;
    return DateTime.now().difference(seen) < staleAfter;
  }

  DriverModel copyWith({
    String? id,
    String? fullName,
    String? phone,
    Object? avatarUrl = _sentinel,
    double? rating,
    int? totalTrips,
    Object? vehicle = _sentinel,
    bool? isOnline,
    bool? isVerified,
    Object? latitude = _sentinel,
    Object? longitude = _sentinel,
    Object? headingDegrees = _sentinel,
    Object? lastSeenAt = _sentinel,
    String? locale,
  }) {
    return DriverModel(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      avatarUrl: avatarUrl == _sentinel ? this.avatarUrl : avatarUrl as String?,
      rating: rating ?? this.rating,
      totalTrips: totalTrips ?? this.totalTrips,
      vehicle: vehicle == _sentinel ? this.vehicle : vehicle as VehicleInfo?,
      isOnline: isOnline ?? this.isOnline,
      isVerified: isVerified ?? this.isVerified,
      latitude: latitude == _sentinel ? this.latitude : latitude as double?,
      longitude:
          longitude == _sentinel ? this.longitude : longitude as double?,
      headingDegrees: headingDegrees == _sentinel
          ? this.headingDegrees
          : headingDegrees as double?,
      lastSeenAt:
          lastSeenAt == _sentinel ? this.lastSeenAt : lastSeenAt as DateTime?,
      locale: locale ?? this.locale,
    );
  }

  factory DriverModel.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    final user = userJson is Map
        ? UserModel.fromJson(userJson.cast<String, dynamic>())
        : null;

    final vehicleJson = json['vehicle'];
    final vehicle = vehicleJson is Map
        ? VehicleInfo.fromJson(vehicleJson.cast<String, dynamic>())
        : null;

    return DriverModel(
      id: _string(json['id']) ??
          _string(json['driver_id']) ??
          user?.id ??
          '',
      fullName: _string(json['full_name']) ??
          _string(json['name']) ??
          user?.fullName ??
          '',
      phone: _string(json['phone']) ??
          _string(json['phone_number']) ??
          user?.phone ??
          '',
      avatarUrl: _string(json['avatar_url']) ??
          _string(json['avatarUrl']) ??
          user?.avatarUrl,
      rating: _double(json['rating']) ?? _double(json['avg_rating']) ?? 5.0,
      totalTrips: _int(json['total_trips']) ??
          _int(json['trips']) ??
          _int(json['completed_trips']) ??
          0,
      vehicle: vehicle,
      isOnline:
          _bool(json['is_online']) ?? _bool(json['online']) ?? false,
      isVerified:
          _bool(json['is_verified']) ?? _bool(json['verified']) ?? false,
      latitude: _double(json['latitude']) ?? _double(json['lat']),
      longitude: _double(json['longitude']) ?? _double(json['lng']),
      headingDegrees: _double(json['heading']) ??
          _double(json['bearing']) ??
          _double(json['heading_degrees']),
      lastSeenAt: _date(json['last_seen_at']) ?? _date(json['updated_at']),
      locale: _string(json['locale']) ?? user?.locale ?? 'en',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'full_name': fullName,
        'phone': phone,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        'rating': rating,
        'total_trips': totalTrips,
        if (vehicle != null) 'vehicle': vehicle!.toJson(),
        'is_online': isOnline,
        'is_verified': isVerified,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
        if (headingDegrees != null) 'heading': headingDegrees,
        if (lastSeenAt != null) 'last_seen_at': lastSeenAt!.toIso8601String(),
        'locale': locale,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DriverModel &&
        other.id == id &&
        other.fullName == fullName &&
        other.phone == phone &&
        other.avatarUrl == avatarUrl &&
        other.rating == rating &&
        other.totalTrips == totalTrips &&
        other.vehicle == vehicle &&
        other.isOnline == isOnline &&
        other.isVerified == isVerified &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.headingDegrees == headingDegrees &&
        other.lastSeenAt == lastSeenAt &&
        other.locale == locale;
  }

  @override
  int get hashCode => Object.hash(
        id,
        fullName,
        phone,
        avatarUrl,
        rating,
        totalTrips,
        vehicle,
        isOnline,
        isVerified,
        latitude,
        longitude,
        headingDegrees,
        lastSeenAt,
        locale,
      );

  @override
  String toString() =>
      'DriverModel(id: $id, name: $fullName, online: $isOnline, '
      'pos: ($latitude, $longitude))';
}

@immutable
class VehicleInfo {
  const VehicleInfo({
    required this.make,
    required this.model,
    required this.plateNumber,
    this.color,
    this.year,
    this.vehicleClass = VehicleClass.standard,
    this.seats = 4,
    this.photoUrl,
  });

  final String make;
  final String model;
  final String plateNumber;
  final String? color;
  final int? year;
  final VehicleClass vehicleClass;
  final int seats;
  final String? photoUrl;

  String get displayName {
    final parts = <String>[
      make,
      model,
      if (color != null && color!.isNotEmpty) color!,
    ].where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? 'Vehicle' : parts.join(' ');
  }

  String get displayPlate => plateNumber.trim().toUpperCase();

  VehicleInfo copyWith({
    String? make,
    String? model,
    String? plateNumber,
    Object? color = _sentinel,
    Object? year = _sentinel,
    VehicleClass? vehicleClass,
    int? seats,
    Object? photoUrl = _sentinel,
  }) {
    return VehicleInfo(
      make: make ?? this.make,
      model: model ?? this.model,
      plateNumber: plateNumber ?? this.plateNumber,
      color: color == _sentinel ? this.color : color as String?,
      year: year == _sentinel ? this.year : year as int?,
      vehicleClass: vehicleClass ?? this.vehicleClass,
      seats: seats ?? this.seats,
      photoUrl: photoUrl == _sentinel ? this.photoUrl : photoUrl as String?,
    );
  }

  factory VehicleInfo.fromJson(Map<String, dynamic> json) {
    return VehicleInfo(
      make: _string(json['make']) ?? _string(json['brand']) ?? '',
      model: _string(json['model']) ?? '',
      plateNumber: _string(json['plate']) ??
          _string(json['plate_number']) ??
          _string(json['license_plate']) ??
          '',
      color: _string(json['color']),
      year: _int(json['year']),
      vehicleClass: VehicleClassX.fromString(
        _string(json['class']) ?? _string(json['vehicle_class']),
      ),
      seats: _int(json['seats']) ?? _int(json['capacity']) ?? 4,
      photoUrl: _string(json['photo_url']) ?? _string(json['image']),
    );
  }

  Map<String, dynamic> toJson() => {
        'make': make,
        'model': model,
        'plate': plateNumber,
        if (color != null) 'color': color,
        if (year != null) 'year': year,
        'vehicle_class': vehicleClass.wire,
        'seats': seats,
        if (photoUrl != null) 'photo_url': photoUrl,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VehicleInfo &&
        other.make == make &&
        other.model == model &&
        other.plateNumber == plateNumber &&
        other.color == color &&
        other.year == year &&
        other.vehicleClass == vehicleClass &&
        other.seats == seats &&
        other.photoUrl == photoUrl;
  }

  @override
  int get hashCode => Object.hash(
        make,
        model,
        plateNumber,
        color,
        year,
        vehicleClass,
        seats,
        photoUrl,
      );

  @override
  String toString() =>
      'VehicleInfo($displayName, plate: $plateNumber, class: ${vehicleClass.wire})';
}

enum VehicleClass { standard, moto, xl, premium }

extension VehicleClassX on VehicleClass {
  String get wire => switch (this) {
        VehicleClass.standard => 'standard',
        VehicleClass.moto => 'moto',
        VehicleClass.xl => 'xl',
        VehicleClass.premium => 'premium',
      };

  String get label => switch (this) {
        VehicleClass.standard => 'Standard',
        VehicleClass.moto => 'Moto',
        VehicleClass.xl => 'XL',
        VehicleClass.premium => 'Premium',
      };

  String get description => switch (this) {
        VehicleClass.standard => 'Affordable everyday rides',
        VehicleClass.moto => 'Fast and cheap on two wheels',
        VehicleClass.xl => 'Extra space for groups and luggage',
        VehicleClass.premium => 'High-end cars, top-rated drivers',
      };

  double get fareMultiplier => switch (this) {
        VehicleClass.standard => 1.0,
        VehicleClass.moto => 0.65,
        VehicleClass.xl => 1.45,
        VehicleClass.premium => 1.9,
      };

  static VehicleClass fromString(String? raw) {
    switch ((raw ?? '').toLowerCase().trim()) {
      case 'moto':
      case 'boda':
      case 'bike':
      case 'motorcycle':
        return VehicleClass.moto;
      case 'xl':
      case 'van':
      case 'suv':
        return VehicleClass.xl;
      case 'premium':
      case 'luxury':
      case 'exec':
        return VehicleClass.premium;
      case 'standard':
      case 'car':
      default:
        return VehicleClass.standard;
    }
  }
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

bool? _bool(dynamic v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase().trim();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return null;
}

double? _double(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final parsed = int.tryParse(v.trim());
    if (parsed != null) return parsed;
    final asDouble = double.tryParse(v.trim());
    return asDouble?.toInt();
  }
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