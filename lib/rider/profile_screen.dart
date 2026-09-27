import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/auth_service.dart';
import '../../models/user_model.dart';
import '../../shared/custom_modal.dart';
import '../../shared/custom_modal.dart' show SheetPrimaryButton;
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
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: AppConstants.sheetDuration,
      pageBuilder: (_, __, ___) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: currentCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current password',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
              validator: (v) {
                if (v != newCtrl.text) return 'Passwords do not match';
                return null;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (newCtrl.text.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password must be at least 6 characters')),
                );
                return;
              }
              if (newCtrl.text != confirmCtrl.text) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Passwords do not match')),
                );
                return;
              }
              try {
                await _auth.updatePassword(
                  currentPassword: currentCtrl.text,
                  newPassword: newCtrl.text,
                );
                if (!mounted) return;
                Navigator.of(context).pop();
                setState(() => _success = 'Password updated successfully');
              } on ApiException catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.message), backgroundColor: Theme.of(context).colorScheme.error),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
      transitionBuilder: (_, anim, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        child: child,
      ),
    );
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
        appBar: AppBar(title: const Text('Profile')),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Header: Avatar + Name + Stats ---
              _buildHeader(theme, scheme, user),
              const SizedBox(height: AppTheme.spaceLg),

              // --- Status messages ---
              if (_error != null)
                _statusBanner(scheme, _error!, isError: true),
              if (_success != null)
                _statusBanner(scheme, _success!, isError: false),

              // --- Quick actions grid ---
              _buildQuickActions(theme, scheme),

              // --- Profile form ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
                child: Text(
                  'Profile Details',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.spaceLg),
                  child: Column(
                    children: [
                      _formField(theme, scheme,
                        controller: _nameCtrl,
                        label: 'Full Name',
                        icon: Icons.person_outline_rounded,
                      ),
                      const SizedBox(height: AppTheme.spaceLg),
                      _formField(theme, scheme,
                        controller: _emailCtrl,
                        label: 'Email',
                        icon: Icons.email_outlined,
                      ),
                      const SizedBox(height: AppTheme.spaceLg),
                      _formField(theme, scheme,
                        controller: _phoneCtrl,
                        label: 'Phone',
                        icon: Icons.phone_outlined,
                      ),
                      const SizedBox(height: AppTheme.spaceLg),
                      _actionTile(
                        theme,
                        scheme,
                        icon: Icons.lock_outline_rounded,
                        iconColor: AppTheme.info,
                        title: 'Change Password',
                        subtitle: 'Update your password',
                        onTap: _changePassword,
                      ),
                      const SizedBox(height: AppTheme.spaceMd),
                      SheetPrimaryButton(
                        label: 'Save changes',
                        icon: Icons.save_outlined,
                        isLoading: _busy,
                        onPressed: _busy ? null : _updateProfile,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppTheme.spaceLg),

              // --- Settings list ---
              _buildSettingsList(theme, scheme, user),
              const SizedBox(height: AppTheme.spaceLg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ColorScheme scheme, UserModel user) {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      child: Column(
        children: [
          CircleAvatar(
            radius: 56,
            backgroundColor: scheme.primary.withValues(alpha: 0.12),
            child: Text(
              user.initials,
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(height: AppTheme.spaceMd),
          Text(
            user.fullName,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            user.email ?? user.phone,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spaceLg),
        ],
      ),
    );
  }

  Widget _buildQuickActions(ThemeData theme, ColorScheme scheme) {
    final actions = [
      _QuickAction(
        icon: Icons.history_rounded,
        iconColor: AppTheme.info,
        label: 'My Rides',
        onTap: () => Navigator.of(context).pushNamed('/profile/rides'),
      ),
      _QuickAction(
        icon: Icons.wallet_outlined,
        iconColor: AppTheme.warning,
        label: 'Payment',
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment methods coming soon')),
        ),
      ),
      _QuickAction(
        icon: Icons.notifications_outlined,
        iconColor: scheme.primary,
        label: 'Notifications',
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification settings coming soon')),
        ),
      ),
      _QuickAction(
        icon: Icons.help_outline_rounded,
        iconColor: AppTheme.success,
        label: 'Help',
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Help center coming soon')),
        ),
      ),
    ];

    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
        itemCount: actions.length,
        separatorBuilder: (_, __) => const SizedBox(width: AppTheme.spaceMd),
        itemBuilder: (_, i) => _quickActionCard(theme, scheme, actions[i]),
      ),
    );
  }

  Widget _quickActionCard(ThemeData theme, ColorScheme scheme, _QuickAction action) {
    return SizedBox(
      width: 96,
      child: Column(
        children: [
          Material(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              onTap: action.onTap,
              child: SizedBox(
                width: 72,
                height: 72,
                child: Center(
                  child: Icon(action.icon, size: 32, color: action.iconColor),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            action.label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsList(ThemeData theme, ColorScheme scheme, UserModel user) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
      child: Column(
        children: [
          _actionTile(
            theme,
            scheme,
            icon: Icons.receipt_long_outlined,
            iconColor: scheme.primary,
            title: 'Ride History',
            subtitle: 'Completed and cancelled rides',
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => Navigator.of(context).pushNamed('/profile/rides'),
          ),
          const Divider(height: 1),
          _actionTile(
            theme,
            scheme,
            icon: Icons.shield_outlined,
            iconColor: AppTheme.success,
            title: 'Privacy Policy',
            subtitle: 'How we use your data',
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Privacy policy coming soon')),
            ),
          ),
          const Divider(height: 1),
          _actionTile(
            theme,
            scheme,
            icon: Icons.info_outline_rounded,
            iconColor: AppTheme.info,
            title: 'About FastRide',
            subtitle: 'Version 1.0.0',
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('About FastRide')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile(
    ThemeData theme,
    ColorScheme scheme, {
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return ListTile(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: iconColor),
      ),
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: trailing,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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

  Widget _statusBanner(ColorScheme scheme, String message, {required bool isError}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl, vertical: AppTheme.spaceSm),
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceLg, vertical: AppTheme.spaceMd),
      decoration: BoxDecoration(
        color: (isError ? AppTheme.danger : AppTheme.success).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            size: 20,
            color: isError ? AppTheme.danger : AppTheme.success,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: isError ? AppTheme.danger : AppTheme.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Static helpers that show profile-related modals so they can be
/// invoked from any screen (e.g. the rider dashboard sidebar)
/// without navigating away from the current route.

Future<void> showChangePasswordDialog({
  required BuildContext context,
  required AuthService auth,
}) async {
  final currentCtrl = TextEditingController();
  final newCtrl = TextEditingController();
  final confirmCtrl = TextEditingController();

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: AppConstants.sheetDuration,
    pageBuilder: (_, __, ___) => AlertDialog(
      title: const Text('Change password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: currentCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Current password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: newCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'New password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: confirmCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
            validator: (v) {
              if (v != newCtrl.text) return 'Passwords do not match';
              return null;
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (newCtrl.text.length < 6) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Password must be at least 6 characters')),
              );
              return;
            }
            if (newCtrl.text != confirmCtrl.text) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Passwords do not match')),
              );
              return;
            }
            try {
              await auth.updatePassword(
                currentPassword: currentCtrl.text,
                newPassword: newCtrl.text,
              );
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Password updated successfully')),
              );
            } on ApiException catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(e.message),
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                );
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
    transitionBuilder: (_, anim, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
      child: child,
    ),
  );
}

/// Shows an editable profile sheet that stays within the current route
/// (no navigation to a separate page).
Future<void> showEditProfile({
  required BuildContext context,
  required AuthService auth,
  required ApiClient api,
}) async {
  final nameCtrl = TextEditingController(text: auth.user?.fullName ?? '');
  final phoneCtrl = TextEditingController(text: auth.user?.phone ?? '');
  final emailCtrl = TextEditingController(text: auth.user?.email ?? '');
  bool busy = false;
  String? error;
  String? success;

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: AppConstants.sheetDuration,
    pageBuilder: (_, __, ___) => StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: const Text('Edit profile'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                if (success != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(success!,
                        style: const TextStyle(color: AppTheme.success)),
                  ),
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Full Name',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: phoneCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Phone',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        await auth.updateProfile(
                          fullName: nameCtrl.text.trim(),
                          phone: phoneCtrl.text.trim(),
                          email: emailCtrl.text.trim().isEmpty
                              ? null
                              : emailCtrl.text.trim(),
                        );
                        setState(() {
                          busy = false;
                          success = 'Profile updated successfully';
                        });
                      } on ApiException catch (e) {
                        setState(() {
                          busy = false;
                          error = e.message;
                        });
                      } catch (_) {
                        setState(() {
                          busy = false;
                          error = 'Something went wrong. Please try again.';
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                   : const Text('Save'),
            ),
          ],
        );
      },
    ),
    transitionBuilder: (_, anim, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
      child: child,
    ),
  );
}

class _QuickAction {
  const _QuickAction({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;
}
