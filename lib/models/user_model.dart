import 'package:flutter/foundation.dart';

@immutable
class UserModel {
  const UserModel({
    required this.id,
    required this.fullName,
    required this.phone,
    this.email,
    this.avatarUrl,
    this.role = UserRole.rider,
    this.locale = 'en',
    this.isVerified = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String fullName;
  final String phone;
  final String? email;
  final String? avatarUrl;
  final UserRole role;
  final String locale;
  final bool isVerified;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get initials {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    final first = parts.first.substring(0, 1);
    final last = parts.last.substring(0, 1);
    return '$first$last'.toUpperCase();
  }

  String get firstName {
    final trimmed = fullName.trim();
    if (trimmed.isEmpty) return 'there';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  String get maskedPhone {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) return phone;
    final country = phone.startsWith('+') ? '+${digits.substring(0, 1)}' : '';
    final lastThree = digits.substring(digits.length - 3);
    final rest = digits.substring(
      country.isEmpty ? 0 : 1,
      digits.length - 3,
    );
    final masked = '•' * rest.length;
    return '$country $masked$lastThree'.trim();
  }

  UserModel copyWith({
    String? id,
    String? fullName,
    String? phone,
    Object? email = _sentinel,
    Object? avatarUrl = _sentinel,
    UserRole? role,
    String? locale,
    bool? isVerified,
    Object? createdAt = _sentinel,
    Object? updatedAt = _sentinel,
  }) {
    return UserModel(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      email: email == _sentinel ? this.email : email as String?,
      avatarUrl:
          avatarUrl == _sentinel ? this.avatarUrl : avatarUrl as String?,
      role: role ?? this.role,
      locale: locale ?? this.locale,
      isVerified: isVerified ?? this.isVerified,
      createdAt:
          createdAt == _sentinel ? this.createdAt : createdAt as DateTime?,
      updatedAt:
          updatedAt == _sentinel ? this.updatedAt : updatedAt as DateTime?,
    );
  }

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: _string(json['id']) ?? _string(json['user_id']) ?? '',
      fullName: _string(json['full_name']) ??
          _string(json['name']) ??
          _string(json['fullName']) ??
          '',
      phone: _string(json['phone']) ?? _string(json['phone_number']) ?? '',
      email: _string(json['email']),
      avatarUrl: _string(json['avatar_url']) ??
          _string(json['avatarUrl']) ??
          _string(json['photo']),
      role: UserRoleX.fromString(
        _string(json['role']) ?? _string(json['user_type']),
      ),
      locale: _string(json['locale']) ?? 'en',
      isVerified:
          _bool(json['is_verified']) ?? _bool(json['verified']) ?? false,
      createdAt: _date(json['created_at']) ?? _date(json['createdAt']),
      updatedAt: _date(json['updated_at']) ?? _date(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'full_name': fullName,
        'phone': phone,
        if (email != null) 'email': email,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        'role': role.wire,
        'locale': locale,
        'is_verified': isVerified,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserModel &&
        other.id == id &&
        other.fullName == fullName &&
        other.phone == phone &&
        other.email == email &&
        other.avatarUrl == avatarUrl &&
        other.role == role &&
        other.locale == locale &&
        other.isVerified == isVerified &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
        id,
        fullName,
        phone,
        email,
        avatarUrl,
        role,
        locale,
        isVerified,
        createdAt,
        updatedAt,
      );

  @override
  String toString() =>
      'UserModel(id: $id, name: $fullName, role: ${role.wire})';
}

enum UserRole { rider, driver, admin }

extension UserRoleX on UserRole {
  String get wire => switch (this) {
        UserRole.rider => 'rider',
        UserRole.driver => 'driver',
        UserRole.admin => 'admin',
      };

  String get label => switch (this) {
        UserRole.rider => 'Rider',
        UserRole.driver => 'Driver',
        UserRole.admin => 'Admin',
      };

  static UserRole fromString(String? raw) {
    switch ((raw ?? '').toLowerCase().trim()) {
      case 'driver':
        return UserRole.driver;
      case 'admin':
        return UserRole.admin;
      case 'rider':
      case 'passenger':
      case 'customer':
      default:
        return UserRole.rider;
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