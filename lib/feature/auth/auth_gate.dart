import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/auth_service.dart';
import '../../models/user_model.dart';
import '../../shared/custom_modal.dart';
import '../../theme.dart';
import 'login_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final AuthService _auth = AuthService(
    api: ApiClient(
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
    ),
  );

  bool _ready = false;
  bool _isAuthenticated = false;
  UserRole _userRole = UserRole.rider;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _auth.initialize();
    if (!mounted) return;
    setState(() {
      _isAuthenticated = _auth.isAuthenticated;
      _userRole = _auth.user?.role ?? UserRole.rider;
      _ready = true;
    });
  }

  Future<void> _onLogout() async {
    await _auth.logout();
    setState(() {
      _isAuthenticated = false;
      _userRole = UserRole.rider;
    });
  }

  void _navigateToDashboard() {
    if (!_isAuthenticated) return;
    if (_userRole == UserRole.driver) {
      Navigator.of(context).pushReplacementNamed('/driver');
    } else {
      Navigator.of(context).pushReplacementNamed('/rider');
    }
  }

  @override
  void dispose() {
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const _LoadingScreen();
    }

    if (_isAuthenticated) {
      return _AuthenticatedShell(onLogout: _onLogout, onMapTap: _navigateToDashboard);
    }

    return const LoginScreen();
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: AppTheme.spaceLg),
            Text(
              'FastRide',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthenticatedShell extends StatelessWidget {
  const _AuthenticatedShell({required this.onLogout, this.onMapTap});

  final VoidCallback onLogout;
  final VoidCallback? onMapTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: AppTheme.spaceLg),
              Text(
                'Authenticated',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Text(
                'Welcome to FastRide',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: AppTheme.space2xl),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: onMapTap,
                  child: const Text('Go to Map'),
                ),
              ),
              const SizedBox(height: AppTheme.spaceMd),
              TextButton.icon(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  AppSheet.show(
                    context: context,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Choose role',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: AppTheme.spaceLg),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: FilledButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                                Navigator.of(context).pushReplacementNamed('/rider');
                              },
                              child: const Text('Rider'),
                            ),
                          ),
                          const SizedBox(height: AppTheme.spaceMd),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: OutlinedButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                                Navigator.of(context).pushReplacementNamed('/driver');
                              },
                              child: const Text('Driver'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.swap_calls_rounded),
                label: const Text('Switch role'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
