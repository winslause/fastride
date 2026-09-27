import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/auth_service.dart';
import '../../shared/custom_modal.dart';
import '../../theme.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final ApiClient _api;
  late AuthService _auth;
  bool _ready = false;
  bool _busy = false;
  String? _error;
  String? _success;

  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _api = ApiClient(
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
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _auth = AuthService(api: _api);
    await _auth.initialize();
    final user = _auth.user;
    if (user != null) {
      _nameCtrl.text = user.fullName;
      _phoneCtrl.text = user.phone;
      _emailCtrl.text = user.email ?? '';
    }
    if (!mounted) return;
    setState(() => _ready = true);
  }

  Future<void> _updateProfile() async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });

    try {
      await _auth.updateProfile(
        fullName: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      );
      if (!mounted) return;
      setState(() => _success = 'Profile updated successfully');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    await _auth.logout();
    if (!mounted) return;
    Navigator.of(context)
      ..popUntil((route) => route.isFirst)
      ..pushReplacementNamed('/auth');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!_ready) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: scheme.primary),
        ),
      );
    }

    final user = _auth.user;
    if (user == null) {
      return Scaffold(
        body: Center(
          child: TextButton.icon(
            onPressed: () =>
                Navigator.of(context).pushReplacementNamed('/auth'),
            icon: const Icon(Icons.login_rounded),
            label: const Text('Sign in'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            onPressed: _logout,
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.spaceXl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Avatar
                Center(
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: scheme.primary.withValues(alpha: 0.12),
                    child: Text(
                      user.initials,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppTheme.spaceLg),

                Text(
                  user.fullName,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  user.email ?? user.phone,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.space2xl),

                // Profile form
                _formField(
                  theme,
                  scheme,
                  controller: _nameCtrl,
                  label: 'Full Name',
                  icon: Icons.person_outline_rounded,
                ),
                const SizedBox(height: AppTheme.spaceLg),
                _formField(
                  theme,
                  scheme,
                  controller: _emailCtrl,
                  label: 'Email',
                  icon: Icons.email_outlined,
                ),
                const SizedBox(height: AppTheme.spaceLg),
                _formField(
                  theme,
                  scheme,
                  controller: _phoneCtrl,
                  label: 'Phone',
                  icon: Icons.phone_outlined,
                ),
                const SizedBox(height: AppTheme.space2xl),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.spaceMd),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_success != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.spaceMd),
                    child: Text(
                      _success!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.success,
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),

                SheetPrimaryButton(
                  label: 'Save changes',
                  icon: Icons.save_outlined,
                  isLoading: _busy,
                  onPressed: _busy ? null : _updateProfile,
                ),
                const SizedBox(height: AppTheme.spaceLg),

                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushNamed('/profile/rides');
                  },
                  icon: const Icon(Icons.history_rounded),
                  label: const Text('Ride history'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.primary,
                    side: BorderSide(color: scheme.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _formField(
    ThemeData theme,
    ColorScheme scheme, {
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
      ),
      textInputAction: TextInputAction.next,
      onFieldSubmitted: (_) => _updateProfile(),
    );
  }
}
