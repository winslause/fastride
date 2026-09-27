import 'package:flutter/material.dart';
import '../theme.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final faqs = [
      ('How do I book a ride?', 'Enter your pickup and destination, then select a ride type.'),
      ('Can I cancel a ride?', 'Yes, you can cancel any time before a driver is assigned.'),
      ('How do I pay?', 'Payments are handled through your linked payment methods in the Wallet.'),
      ('What if I forget an item?', 'Use the in-app chat to contact your driver or support.'),
    ];

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Help & Support')),
      body: ListView(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        children: [
          Container(
            padding: const EdgeInsets.all(AppTheme.spaceLg),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Row(
              children: [
                Icon(Icons.chat_bubble_rounded, color: scheme.primary, size: 32),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Chat with support',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'We\'re here to help 24/7',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.spaceLg),
          Text(
            'FAQs',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppTheme.spaceMd),
          ...faqs.map((faq) => _faqItem(theme, scheme, faq.$1, faq.$2)),
        ],
      ),
    );
  }

  Widget _faqItem(ThemeData theme, ColorScheme scheme, String question, String answer) {
    return Card(
      child: ExpansionTile(
        title: Text(
          question,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        iconColor: scheme.primary,
        collapsedIconColor: scheme.onSurfaceVariant,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppTheme.spaceMd),
            child: Text(
              answer,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
