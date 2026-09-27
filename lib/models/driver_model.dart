import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;

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
    this.id = '',
    required this.make,
    required this.model,
    required this.plateNumber,
    this.color,
    this.year,
    this.vehicleClass = VehicleClass.standard,
    this.seats = 4,
    this.photoUrl,
  });

  /// Backend row id. Empty for a vehicle that hasn't been saved yet.
  final String id;
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
    String? id,
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
      id: id ?? this.id,
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
      id: _string(json['id']) ?? '',
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
        'plate_number': plateNumber,
        if (color != null && color!.isNotEmpty) 'color': color,
        if (year != null) 'year': year,
        'vehicle_class': vehicleClass.wire,
        'seats': seats,
        if (photoUrl != null) 'photo_url': photoUrl,
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VehicleInfo &&
        other.id == id &&
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
        id,
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

/// =========================================================================
/// DriverPricing
/// -------------------------------------------------------------------------
/// A driver's own rate card. The driver sets these; every fare they are
/// quoted — to them and to the rider — is derived from them.
/// =========================================================================
@immutable
class DriverPricing {
  const DriverPricing({
    this.baseFare = 50,
    this.pricePerKm = 25,
    this.pricePerMinute = 3,
    this.minimumFare = 100,
    this.currency = 'KES',
  });

  /// Flat charge added to every trip.
  final double baseFare;

  /// The headline number: what the driver charges per kilometre.
  final double pricePerKm;

  final double pricePerMinute;

  /// Floor applied to short trips.
  final double minimumFare;

  final String currency;

  /// The fare for a trip of [distanceMeters] taking [durationSeconds].
  ///
  /// Kept identical to the backend's `_quote_fare` so the amount the driver
  /// sees on an offer never disagrees with the rider's bill.
  double quote({
    required double distanceMeters,
    required double durationSeconds,
  }) {
    final km = distanceMeters <= 0 ? 0.0 : distanceMeters / 1000.0;
    final minutes = durationSeconds <= 0 ? 0.0 : durationSeconds / 60.0;
    final total = baseFare + (km * pricePerKm) + (minutes * pricePerMinute);
    return minimumFare > 0 && total < minimumFare ? minimumFare : total;
  }

  /// Itemised breakdown for display, so the driver can see how a fare is
  /// built up rather than just a total.
  Map<String, double> breakdown({
    required double distanceMeters,
    required double durationSeconds,
  }) {
    final km = distanceMeters <= 0 ? 0.0 : distanceMeters / 1000.0;
    final minutes = durationSeconds <= 0 ? 0.0 : durationSeconds / 60.0;
    return {
      'Base fare': baseFare,
      'Distance (${_trimNumber(km)} km)': km * pricePerKm,
      'Time (${_trimNumber(minutes)} min)': minutes * pricePerMinute,
    };
  }

  DriverPricing copyWith({
    double? baseFare,
    double? pricePerKm,
    double? pricePerMinute,
    double? minimumFare,
    String? currency,
  }) {
    return DriverPricing(
      baseFare: baseFare ?? this.baseFare,
      pricePerKm: pricePerKm ?? this.pricePerKm,
      pricePerMinute: pricePerMinute ?? this.pricePerMinute,
      minimumFare: minimumFare ?? this.minimumFare,
      currency: currency ?? this.currency,
    );
  }

  factory DriverPricing.fromJson(Map<String, dynamic> json) {
    return DriverPricing(
      baseFare: _double(json['base_fare']) ?? _double(json['baseFare']) ?? 50,
      pricePerKm:
          _double(json['price_per_km']) ?? _double(json['pricePerKm']) ?? 25,
      pricePerMinute: _double(json['price_per_minute']) ??
          _double(json['pricePerMinute']) ??
          3,
      minimumFare:
          _double(json['minimum_fare']) ?? _double(json['minimumFare']) ?? 100,
      currency: _string(json['currency']) ?? 'KES',
    );
  }

  Map<String, dynamic> toJson() => {
        'base_fare': baseFare,
        'price_per_km': pricePerKm,
        'price_per_minute': pricePerMinute,
        'minimum_fare': minimumFare,
        'currency': currency,
      };

  @override
  bool operator ==(Object other) =>
      other is DriverPricing &&
      other.baseFare == baseFare &&
      other.pricePerKm == pricePerKm &&
      other.pricePerMinute == pricePerMinute &&
      other.minimumFare == minimumFare &&
      other.currency == currency;

  @override
  int get hashCode => Object.hash(
        baseFare,
        pricePerKm,
        pricePerMinute,
        minimumFare,
        currency,
      );
}

String _trimNumber(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(1);
}

/// =========================================================================
/// FareBreakdown
/// -------------------------------------------------------------------------
/// A fare itemised the way the backend quoted it, so the rider sees the exact
/// same lines the driver set up in their rate card.
/// =========================================================================
@immutable
class FareBreakdown {
  const FareBreakdown({
    required this.baseFare,
    required this.distanceFare,
    required this.timeFare,
    required this.subtotal,
    required this.minimumFare,
    required this.total,
    this.minimumApplied = false,
    this.currency = 'KES',
  });

  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double subtotal;
  final double minimumFare;
  final double total;
  final bool minimumApplied;
  final String currency;

  factory FareBreakdown.fromJson(Map<String, dynamic> json) {
    return FareBreakdown(
      baseFare: _double(json['base_fare']) ?? 0,
      distanceFare: _double(json['distance_fare']) ?? 0,
      timeFare: _double(json['time_fare']) ?? 0,
      subtotal: _double(json['subtotal']) ?? 0,
      minimumFare: _double(json['minimum_fare']) ?? 0,
      total: _double(json['total']) ?? 0,
      minimumApplied: json['minimum_applied'] as bool? ?? false,
      currency: _string(json['currency']) ?? 'KES',
    );
  }

  /// Rebuild a breakdown locally from a rate card, matching the backend's
  /// `_fare_breakdown` so both sides always agree.
  factory FareBreakdown.fromPricing(
    DriverPricing pricing, {
    required double distanceMeters,
    required double durationSeconds,
  }) {
    final km = distanceMeters <= 0 ? 0.0 : distanceMeters / 1000.0;
    final minutes = durationSeconds <= 0 ? 0.0 : durationSeconds / 60.0;
    final distanceFare = km * pricing.pricePerKm;
    final timeFare = minutes * pricing.pricePerMinute;
    final subtotal = pricing.baseFare + distanceFare + timeFare;
    final applied = pricing.minimumFare > 0 && subtotal < pricing.minimumFare;
    return FareBreakdown(
      baseFare: pricing.baseFare,
      distanceFare: distanceFare,
      timeFare: timeFare,
      subtotal: subtotal,
      minimumFare: pricing.minimumFare,
      total: applied ? pricing.minimumFare : subtotal,
      minimumApplied: applied,
      currency: pricing.currency,
    );
  }

  Map<String, double> get lines => {
        'Base fare': baseFare,
        'Distance': distanceFare,
        'Time': timeFare,
      };

  @override
  bool operator ==(Object other) =>
      other is FareBreakdown && other.total == total && other.subtotal == subtotal;

  @override
  int get hashCode => Object.hash(total, subtotal);
}

/// =========================================================================
/// DriverService
/// -------------------------------------------------------------------------
/// An extra, bookable offering a driver publishes on top of a normal ride
/// (airport transfer, large luggage, pet friendly, hourly hire, …).
/// =========================================================================
@immutable
class DriverService {
  const DriverService({
    required this.id,
    required this.name,
    this.description,
    this.price,
    this.currency = 'KES',
    this.durationMinutes,
    this.icon,
    this.isActive = true,
    this.createdAt,
  });

  final String id;
  final String name;
  final String? description;
  final double? price;
  final String currency;
  final int? durationMinutes;
  final String? icon;
  final bool isActive;
  final DateTime? createdAt;

  String? get priceLabel {
    final p = price;
    if (p == null) return null;
    if (p <= 0) return 'Free';
    return '${_currencySymbol(currency)}${p.toStringAsFixed(2)}';
  }

  String? get durationLabel {
    final d = durationMinutes;
    if (d == null || d <= 0) return null;
    if (d < 60) return '$d min';
    final h = d ~/ 60;
    final r = d % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }

  /// Maps the free-form icon key stored in the backend to a Material icon.
  IconData get iconData => switch (icon) {
        'airport' => Icons.flight_rounded,
        'luggage' => Icons.luggage_rounded,
        'pet' => Icons.pets_rounded,
        'hourly' => Icons.schedule_rounded,
        'boda' => Icons.two_wheeler_rounded,
        'ac' => Icons.ac_unit_rounded,
        'wifi' => Icons.wifi_rounded,
        'child_seat' => Icons.child_care_rounded,
        _ => Icons.local_offer_rounded,
      };

  DriverService copyWith({
    String? name,
    Object? description = _sentinel,
    Object? price = _sentinel,
    String? currency,
    Object? durationMinutes = _sentinel,
    Object? icon = _sentinel,
    bool? isActive,
  }) {
    return DriverService(
      id: id,
      name: name ?? this.name,
      description:
          description == _sentinel ? this.description : description as String?,
      price: price == _sentinel ? this.price : price as double?,
      currency: currency ?? this.currency,
      durationMinutes: durationMinutes == _sentinel
          ? this.durationMinutes
          : durationMinutes as int?,
      icon: icon == _sentinel ? this.icon : icon as String?,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
    );
  }

  factory DriverService.fromJson(Map<String, dynamic> json) {
    return DriverService(
      id: _string(json['id']) ?? '',
      name: _string(json['name']) ?? 'Service',
      description: _string(json['description']),
      price: _double(json['price']),
      currency: _string(json['currency']) ?? 'KES',
      durationMinutes:
          _int(json['duration_minutes']) ?? _int(json['durationMinutes']),
      icon: _string(json['icon']),
      isActive: _bool(json['is_active']) ?? _bool(json['isActive']) ?? true,
      createdAt: _date(json['created_at']) ?? _date(json['createdAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        if (description != null) 'description': description,
        if (price != null) 'price': price,
        'currency': currency,
        if (durationMinutes != null) 'duration_minutes': durationMinutes,
        if (icon != null) 'icon': icon,
        'is_active': isActive,
      };

  @override
  bool operator ==(Object other) =>
      other is DriverService &&
      other.id == id &&
      other.name == name &&
      other.description == description &&
      other.price == price &&
      other.currency == currency &&
      other.durationMinutes == durationMinutes &&
      other.icon == icon &&
      other.isActive == isActive;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        description,
        price,
        currency,
        durationMinutes,
        icon,
        isActive,
      );
}

/// =========================================================================
/// DriverStats
/// -------------------------------------------------------------------------
/// The numbers on the driver dashboard: how many rides, how much earned.
/// =========================================================================
@immutable
class DriverStats {
  const DriverStats({
    this.totalRides = 0,
    this.todayRides = 0,
    this.todayEarnings = 0,
    this.lifetimeEarnings = 0,
    this.avgPerRide = 0,
  });

  final int totalRides;
  final int todayRides;
  final double todayEarnings;
  final double lifetimeEarnings;
  final double avgPerRide;

  String get totalRidesLabel => '$totalRides';

  String get todayRidesLabel => '$todayRides';

  factory DriverStats.fromJson(Map<String, dynamic> json) {
    return DriverStats(
      totalRides: _int(json['total_rides']) ??
          _int(json['total_trips']) ??
          _int(json['totalRides']) ??
          0,
      todayRides:
          _int(json['today_rides']) ?? _int(json['todayRides']) ?? 0,
      todayEarnings: _double(json['today_earnings']) ??
          _double(json['todayEarnings']) ??
          0,
      lifetimeEarnings: _double(json['lifetime_earnings']) ??
          _double(json['lifetimeEarnings']) ??
          0,
      avgPerRide:
          _double(json['avg_per_ride']) ?? _double(json['avgPerRide']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'total_rides': totalRides,
        'today_rides': todayRides,
        'today_earnings': todayEarnings,
        'lifetime_earnings': lifetimeEarnings,
        'avg_per_ride': avgPerRide,
      };
}

/// =========================================================================
/// DriverProfile
/// -------------------------------------------------------------------------
/// Everything `GET /drivers/me` returns: the driver record, their lifetime
/// stats, the cars they drive and the services they offer.
/// =========================================================================
@immutable
class DriverProfile {
  const DriverProfile({
    required this.driver,
    this.stats = const DriverStats(),
    this.pricing = const DriverPricing(),
    this.vehicles = const [],
    this.services = const [],
  });

  final DriverModel driver;
  final DriverStats stats;
  final DriverPricing pricing;
  final List<VehicleInfo> vehicles;
  final List<DriverService> services;

  VehicleInfo? get defaultVehicle {
    if (vehicles.isEmpty) return null;
    return vehicles.first;
  }

  int get vehicleCount => vehicles.length;

  int get activeServiceCount => services.where((s) => s.isActive).length;

  factory DriverProfile.fromJson(Map<String, dynamic> json) {
    final driverJson = json['driver'];
    final statsJson = json['stats'];
    final pricingJson = json['pricing'];
    final vehiclesJson = json['vehicles'];
    final servicesJson = json['services'];

    return DriverProfile(
      driver: DriverModel.fromJson(
        driverJson is Map ? driverJson.cast<String, dynamic>() : json,
      ),
      stats: statsJson is Map
          ? DriverStats.fromJson(statsJson.cast<String, dynamic>())
          : const DriverStats(),
      pricing: pricingJson is Map
          ? DriverPricing.fromJson(pricingJson.cast<String, dynamic>())
          : const DriverPricing(),
      vehicles: vehiclesJson is List
          ? vehiclesJson
              .whereType<Map>()
              .map((v) => VehicleInfo.fromJson(v.cast<String, dynamic>()))
              .toList()
          : const [],
      services: servicesJson is List
          ? servicesJson
              .whereType<Map>()
              .map((s) => DriverService.fromJson(s.cast<String, dynamic>()))
              .toList()
          : const [],
    );
  }
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

String _currencySymbol(String code) => switch (code.toUpperCase()) {
      'KES' => 'KSh ',
      'USD' => r'$',
      'EUR' => '€',
      'GBP' => '£',
      'NGN' => '₦',
      'UGX' => 'USh ',
      'TZS' => 'TSh ',
      'ZAR' => 'R',
      'INR' => '₹',
      _ => '$code ',
    };

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