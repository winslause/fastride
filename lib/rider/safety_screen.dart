import 'package:flutter/material.dart';
import '../theme.dart';

class SafetyScreen extends StatelessWidget {
  const SafetyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final tips = [
      ('Share your trip', 'Share your ride details with trusted contacts.', Icons.share_rounded),
      ('SOS button', 'Tap the emergency button to alert authorities.', Icons.sos_rounded),
      ('Driver info', 'View your driver\'s details before accepting.', Icons.person_rounded),
      ('Route tracking', 'Your ride is tracked in real-time.', Icons.location_on_rounded),
    ];

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Safety Centre')),
      body: ListView(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        children: [
          Container(
            padding: const EdgeInsets.all(AppTheme.spaceLg),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Row(
              children: [
                const Icon(Icons.shield_rounded, color: AppTheme.success, size: 32),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Text(
                    'Your safety is our priority.',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.success,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.spaceLg),
          Text(
            'Safety tips',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.spaceMd),
          ...tips.map((tip) => _safetyTip(theme, scheme, tip.$1, tip.$2, tip.$3)),
        ],
      ),
    );
  }

  Widget _safetyTip(ThemeData theme, ColorScheme scheme, String title, String desc, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spaceLg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: scheme.primary, size: 22),
          ),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  desc,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
