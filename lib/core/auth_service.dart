import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import '../models/user_model.dart';

/// Owns authentication state, token persistence, and profile updates.
class AuthService extends ChangeNotifier {
  AuthService({
    required ApiClient api,
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
    this.loginPath = '/auth/login',
    this.registerPath = '/auth/register',
    this.profilePath = '/auth/me',
    this.updateProfilePath = '/auth/profile',
    this.logoutPath = '/auth/logout',
  }) : api = api,
       _preferences = preferences,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  final ApiClient api;
  final SharedPreferences? _preferences;
  final FlutterSecureStorage _secureStorage;

  final String loginPath;
  final String registerPath;
  final String profilePath;
  final String updateProfilePath;
  final String logoutPath;

  static const String _tokenKey = 'fastride.auth.token';
  static const String _userKey = 'fastride.auth.user';

  UserModel? _user;
  bool _ready = false;
  bool _busy = false;
  bool _closed = false;

  UserModel? get user => _user;
  bool get isReady => _ready;
  bool get isBusy => _busy;
  bool get isAuthenticated => _user != null;
  String? get accessToken => api.authToken;

  Future<void> initialize() async {
    if (_ready) return;
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final token = await _readToken();
    if (token != null) api.authToken = token;

    final rawUser = prefs.getString(_userKey);
    if (rawUser != null) {
      try {
        final decoded = jsonDecode(rawUser);
        if (decoded is Map) {
          _user = UserModel.fromJson(decoded.cast<String, dynamic>());
        }
      } catch (_) {}
    }

    if (token != null && _user == null) {
      try {
        await _loadProfile();
      } catch (_) {
        await _clearSession();
      }
    }

    _ready = true;
    if (!_closed) notifyListeners();
  }

  Future<UserModel> login({
    required String identifier,
    required String password,
    UserRole? role,
  }) async {
    _setBusy(true);
    try {
      final response = await api.post(
        loginPath,
        body: {
          'identifier': identifier.trim(),
          'password': password,
          if (role != null) 'role': role.wire,
        },
      );
      return _applySession(response);
    } finally {
      _setBusy(false);
    }
  }

  Future<UserModel> register({
    required String fullName,
    required String phone,
    String? email,
    required String password,
    required UserRole role,
  }) async {
    _setBusy(true);
    try {
      final response = await api.post(
        registerPath,
        body: {
          'full_name': fullName.trim(),
          'phone': phone.trim(),
          if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
          'password': password,
          'role': role.wire,
        },
      );
      return _applySession(response);
    } finally {
      _setBusy(false);
    }
  }

  Future<UserModel> refreshProfile() async {
    _setBusy(true);
    try {
      await _loadProfile();
      return _requireUser();
    } finally {
      _setBusy(false);
    }
  }

  Future<UserModel> updateProfile({
    String? fullName,
    String? phone,
    String? email,
  }) async {
    _setBusy(true);
    try {
      final current = _requireUser();
      final response = await api.patch(
        updateProfilePath,
        body: {
          if (fullName != null) 'full_name': fullName.trim(),
          if (phone != null) 'phone': phone.trim(),
          if (email != null) 'email': email.trim(),
        },
      );

      UserModel? updated;
      if (response is Map) {
        final data = _dataMap(response);
        final userJson = data['user'];
        if (userJson is Map) {
          updated = UserModel.fromJson(userJson.cast<String, dynamic>());
        } else if (data.containsKey('id') || data.containsKey('full_name')) {
          updated = UserModel.fromJson(data.cast<String, dynamic>());
        }
      }
      final next =
          updated ??
          current.copyWith(
            fullName: fullName ?? current.fullName,
            phone: phone ?? current.phone,
            email: email ?? current.email,
          );
      await _saveSession(api.authToken, next);
      return next;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> logout() async {
    _setBusy(true);
    try {
      try {
        await api.post(logoutPath);
      } catch (_) {
        // Local sign-out must still succeed when the network is unavailable.
      }
      await _clearSession();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _loadProfile() async {
    final response = await api.get(profilePath);
    if (response is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Profile response is incomplete.',
      );
    }
    final data = _dataMap(response);
    final userJson = data['user'];
    if (userJson is Map) {
      _user = UserModel.fromJson(userJson.cast<String, dynamic>());
    } else if (data.containsKey('id') || data.containsKey('full_name')) {
      _user = UserModel.fromJson(data.cast<String, dynamic>());
    } else {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Profile response is incomplete.',
      );
    }
    await _saveSession(api.authToken, _user!);
    if (!_closed) notifyListeners();
  }

  Future<UserModel> _applySession(dynamic response) async {
    if (response is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Authentication response is incomplete.',
      );
    }
    final data = _dataMap(response);
    final token =
        _string(data['access_token']) ??
        _string(data['token']) ??
        _string(response['access_token']) ??
        _string(response['token']);
    final userJson = data['user'];
    if (token == null || userJson is! Map) {
      throw const ApiException(
        kind: ApiErrorKind.badData,
        message: 'Sign in succeeded, but profile data is missing.',
      );
    }

    final user = UserModel.fromJson(userJson.cast<String, dynamic>());
    api.authToken = token;
    await _saveSession(token, user);
    return user;
  }

  Future<void> _saveSession(String? token, UserModel user) async {
    _user = user;
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    if (token != null) {
      await _secureStorage.write(key: _tokenKey, value: token);
    }
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    if (!_closed) notifyListeners();
  }

  Future<String?> _readToken() async {
    try {
      return await _secureStorage.read(key: _tokenKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearSession() async {
    _user = null;
    api.authToken = null;
    try {
      await _secureStorage.delete(key: _tokenKey);
    } catch (_) {}
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    if (!_closed) notifyListeners();
  }

  UserModel _requireUser() {
    final user = _user;
    if (user == null) {
      throw StateError('Sign in is required.');
    }
    return user;
  }

  void _setBusy(bool value) {
    if (_closed) return;
    _busy = value;
    notifyListeners();
  }

  static Map<String, dynamic> _dataMap(Map<dynamic, dynamic> response) {
    final data = response['data'];
    if (data is Map) return data.cast<String, dynamic>();
    return response.cast<String, dynamic>();
  }

  static String? _string(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
