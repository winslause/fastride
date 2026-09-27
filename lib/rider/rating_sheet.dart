import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../theme.dart';

/// =========================================================================
/// RatingSheet
/// -------------------------------------------------------------------------
/// Shown to the rider once the driver marks the trip complete: pick a star
/// score, optionally add one line of feedback.
///
/// Deliberately minimal — stars and a single reason field. A rider who has
/// just got out of a car should not be made to fill in a survey.
class RatingSheet extends StatefulWidget {
  const RatingSheet({
    super.key,
    required this.api,
    required this.rideId,
    required this.driverName,
  });

  final ApiClient api;
  final String rideId;
  final String driverName;

  /// Returns true when a rating was saved, false when the rider skipped.
  static Future<bool> show({
    required BuildContext context,
    required ApiClient api,
    required String rideId,
    required String driverName,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => RatingSheet(
          api: api,
          rideId: rideId,
          driverName: driverName,
        ),
        fullscreenDialog: true,
      ),
    );
    return saved ?? false;
  }

  @override
  State<RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<RatingSheet> {
  final TextEditingController _reason = TextEditingController();
  int _stars = 0;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_stars == 0 || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.api.rateRide(
        widget.rideId,
        stars: _stars,
        reason: _reason.text,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not send your rating. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final submitted = _saving;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rate your trip'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Skip',
          onPressed: submitted ? null : () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.spaceXl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: CircleAvatar(
                  radius: 34,
                  backgroundColor: scheme.primary.withValues(alpha: 0.14),
                  child: Icon(
                    Icons.directions_car_filled_rounded,
                    size: 32,
                    color: scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              Text(
                'How was ${widget.driverName}?',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Text(
                _stars == 0
                    ? 'Tap a star to rate'
                    : _starsLabel(_stars),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              _starsRow(theme, scheme),
              const SizedBox(height: AppTheme.spaceXl),
              TextField(
                controller: _reason,
                enabled: !submitted,
                maxLines: 2,
                maxLength: 200,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Anything to add? (optional)',
                  hintText: 'Great driving, clean car…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  counterText: '',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppTheme.spaceSm),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.danger,
                  ),
                ),
              ],
              const SizedBox(height: AppTheme.spaceLg),
              FilledButton(
                onPressed: _stars == 0 || submitted ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: submitted
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Submit rating'),
              ),
              const SizedBox(height: AppTheme.spaceSm),
              TextButton(
                onPressed: submitted ? null : () => Navigator.of(context).pop(false),
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _starsRow(ThemeData theme, ColorScheme scheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final filled = i < _stars;
        return IconButton(
          onPressed: _saving
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  setState(() => _stars = i + 1);
                },
          iconSize: 44,
          tooltip: '${i + 1} star${i == 4 ? '' : 's'}',
          icon: Icon(
            filled ? Icons.star_rounded : Icons.star_outline_rounded,
            color: filled
                ? AppTheme.warning
                : scheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        );
      }),
    );
  }

  static String _starsLabel(int stars) => switch (stars) {
        1 => 'Poor — we are sorry',
        2 => 'Below average',
        3 => 'Fine',
        4 => 'Good',
        _ => 'Excellent — thank you',
      };
}
