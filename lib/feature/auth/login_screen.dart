import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/auth_service.dart';
import '../../core/location_service.dart';
import '../../models/user_model.dart';
import '../../shared/custom_modal.dart';
import '../../theme.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _focusId = FocusNode();
  final _passwordFocus = FocusNode();

  bool _busy = false;
  String? _error;
  UserRole _role = UserRole.rider;

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    _focusId.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.selectionClick();
    setState(() {
      _busy = true;
      _error = null;
    });

    final api = ApiClient(
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
    final location = LocationService();
    final auth = AuthService(api: api);

    try {
      await auth.login(
        identifier: _identifierCtrl.text.trim(),
        password: _passwordCtrl.text,
        role: _role,
      );

      await location.ensureReady();

      if (!mounted) return;
      final userRole = auth.user?.role;
      if (userRole == UserRole.driver) {
        Navigator.of(context).pushReplacementNamed('/driver');
      } else {
        Navigator.of(context).pushReplacementNamed('/rider');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goRegister() {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const RegisterScreen(),
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spaceXl,
              AppTheme.spaceXl,
              AppTheme.spaceXl,
              AppTheme.spaceLg,
            ),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _brand(theme, scheme),
                  const SizedBox(height: AppTheme.space2xl),
                  _title(theme, scheme),
                  const SizedBox(height: AppTheme.spaceXs),
                  _subtitle(theme, scheme),
                  const SizedBox(height: AppTheme.spaceXl),
                  _identifierField(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),
                  _passwordField(theme, scheme),
                  const SizedBox(height: AppTheme.spaceSm),
                  if (_error != null) _errorText(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),
                  _loginButton(theme, scheme),
                  const SizedBox(height: AppTheme.spaceMd),
                  _roleSelector(theme, scheme),
                  const SizedBox(height: AppTheme.space2xl),
                  _registerLink(theme, scheme),
                  const SizedBox(height: AppTheme.spaceMd),
                  _backToMap(theme, scheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand(ThemeData theme, ColorScheme scheme) {
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
          boxShadow: AppTheme.softShadow,
        ),
        child: const Icon(Icons.directions_car_rounded, color: Colors.white, size: 30),
      ),
    );
  }

  Widget _title(ThemeData theme, ColorScheme scheme) {
    return Text(
      'Welcome back',
      textAlign: TextAlign.center,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    );
  }

  Widget _subtitle(ThemeData theme, ColorScheme scheme) {
    return Text(
      'Sign in to continue your ride',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _identifierField(ThemeData theme, ColorScheme scheme) {
    return TextFormField(
      controller: _identifierCtrl,
      focusNode: _focusId,
      textInputAction: TextInputAction.next,
      autofocus: true,
      decoration: InputDecoration(
        hintText: 'Email or phone',
        prefixIcon: const Icon(Icons.person_outline_rounded),
        labelText: 'Email or phone',
      ),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return 'Enter your email or phone';
        return null;
      },
    );
  }

  Widget _passwordField(ThemeData theme, ColorScheme scheme) {
    return TextFormField(
      controller: _passwordCtrl,
      focusNode: _passwordFocus,
      textInputAction: TextInputAction.done,
      obscureText: true,
      decoration: InputDecoration(
        hintText: 'Password',
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        labelText: 'Password',
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return 'Enter your password';
        if (v.length < 6) return 'Minimum 6 characters';
        return null;
      },
      onFieldSubmitted: (_) => _login(),
    );
  }

  Widget _errorText(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spaceSm),
      child: Text(
        _error!,
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _loginButton(ThemeData theme, ColorScheme scheme) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: _busy ? null : _login,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
        child: _busy
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: scheme.onPrimary),
              )
            : const Text(
                'Sign In',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 0.2),
              ),
      ),
    );
  }

  Widget _roleSelector(ThemeData theme, ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _roleChip(
          'Rider',
          Icons.person_outline_rounded,
          UserRole.rider,
          scheme,
        ),
        const SizedBox(width: AppTheme.spaceSm),
        _roleChip(
          'Driver',
          Icons.local_taxi_rounded,
          UserRole.driver,
          scheme,
        ),
      ],
    );
  }

  Widget _roleChip(String label, IconData icon, UserRole role, ColorScheme scheme) {
    final selected = _role == role;
    return ChoiceChip(
      selected: selected,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: selected ? scheme.onPrimary : scheme.primary),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
      selectedColor: scheme.primary,
      labelStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? scheme.onPrimary : scheme.primary,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceLg, vertical: AppTheme.spaceSm),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      onSelected: (_) {
        HapticFeedback.selectionClick();
        setState(() => _role = role);
      },
    );
  }

  Widget _registerLink(ThemeData theme, ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          "Don't have an account? ",
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        GestureDetector(
          onTap: _goRegister,
          child: Text(
            'Register',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _backToMap(ThemeData theme, ColorScheme scheme) {
    return Center(
      child: TextButton.icon(
        onPressed: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).pushReplacementNamed('/rider');
        },
        icon: const Icon(Icons.map_outlined, size: 18),
        label: const Text('Continue as guest'),
        style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
      ),
    );
  }
}
