import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/auth_service.dart';
import '../../core/location_service.dart';
import '../../models/user_model.dart';
import '../../shared/custom_modal.dart';
import '../../theme.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _focusName = FocusNode();
  final _focusPhone = FocusNode();
  final _focusEmail = FocusNode();
  final _focusPassword = FocusNode();

  bool _busy = false;
  String? _error;
  UserRole _role = UserRole.rider;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _focusName.dispose();
    _focusPhone.dispose();
    _focusEmail.dispose();
    _focusPassword.dispose();
    super.dispose();
  }

  Future<void> _register() async {
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
      await auth.register(
        fullName: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim().isNotEmpty ? _emailCtrl.text.trim() : null,
        password: _passwordCtrl.text,
        role: _role,
      );

      await location.ensureReady();

      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/auth/login');
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

  void _goLogin() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
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
                  _nameField(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),
                  _phoneField(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),
                  _emailField(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),
                  _passwordField(theme, scheme),
                  const SizedBox(height: AppTheme.spaceSm),
                  if (_error != null) _errorText(theme, scheme),
                  const SizedBox(height: AppTheme.spaceLg),
                  _registerButton(theme, scheme),
                  const SizedBox(height: AppTheme.spaceMd),
                  _roleSelector(theme, scheme),
                  const SizedBox(height: AppTheme.space2xl),
                  _loginLink(theme, scheme),
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
      'Create account',
      textAlign: TextAlign.center,
      style: theme.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    );
  }

  Widget _subtitle(ThemeData theme, ColorScheme scheme) {
    return Text(
      'Sign up to start riding',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _nameField(ThemeData theme, ColorScheme scheme) {
    return TextFormField(
      controller: _nameCtrl,
      focusNode: _focusName,
      textInputAction: TextInputAction.next,
      autofocus: true,
      decoration: InputDecoration(
        hintText: 'Full name',
        prefixIcon: const Icon(Icons.badge_outlined),
        labelText: 'Full name',
      ),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return 'Enter your full name';
        if (v.trim().length < 2) return 'Name too short';
        return null;
      },
    );
  }

  Widget _phoneField(ThemeData theme, ColorScheme scheme) {
    return TextFormField(
      controller: _phoneCtrl,
      focusNode: _focusPhone,
      textInputAction: TextInputAction.next,
      keyboardType: TextInputType.phone,
      decoration: InputDecoration(
        hintText: '+254...',
        prefixIcon: const Icon(Icons.phone_outlined),
        labelText: 'Phone number',
      ),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return 'Enter your phone number';
        if (v.replaceAll(RegExp(r'\D'), '').length < 7) return 'Enter a valid phone number';
        return null;
      },
    );
  }

  Widget _emailField(ThemeData theme, ColorScheme scheme) {
    return TextFormField(
      controller: _emailCtrl,
      focusNode: _focusEmail,
      textInputAction: TextInputAction.next,
      keyboardType: TextInputType.emailAddress,
      decoration: InputDecoration(
        hintText: 'you@example.com (optional)',
        prefixIcon: const Icon(Icons.email_outlined),
        labelText: 'Email',
      ),
      validator: (v) {
        if (v != null && v.trim().isNotEmpty) {
          if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v.trim())) {
            return 'Enter a valid email';
          }
        }
        return null;
      },
    );
  }

  Widget _passwordField(ThemeData theme, ColorScheme scheme) {
    return TextFormField(
      controller: _passwordCtrl,
      focusNode: _focusPassword,
      textInputAction: TextInputAction.done,
      obscureText: true,
      decoration: InputDecoration(
        hintText: 'Min 6 characters',
        prefixIcon: const Icon(Icons.lock_outline_rounded),
        labelText: 'Password',
      ),
      validator: (v) {
        if (v == null || v.isEmpty) return 'Create a password';
        if (v.length < 6) return 'Minimum 6 characters';
        return null;
      },
      onFieldSubmitted: (_) => _register(),
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

  Widget _registerButton(ThemeData theme, ColorScheme scheme) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: _busy ? null : _register,
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
                'Create Account',
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

  Widget _loginLink(ThemeData theme, ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Already have an account? ',
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        GestureDetector(
          onTap: _goLogin,
          child: Text(
            'Sign In',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
