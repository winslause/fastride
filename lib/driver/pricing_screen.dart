import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../models/driver_model.dart';
import '../theme.dart';

/// =========================================================================
/// PricingScreen
/// -------------------------------------------------------------------------
/// Lets a driver set what they charge. `price per kilometre` is the headline
/// setting; base fare, per-minute and the minimum give the driver full
/// control over how a fare is built up.
///
/// Every fare the driver is shown — on an offer, on a trip — is derived from
/// these numbers, so the live preview below lets them sanity-check a change
/// before it affects riders.
/// =========================================================================
class PricingScreen extends StatefulWidget {
  const PricingScreen({
    super.key,
    required this.api,
    required this.onChanged,
    this.initialPricing = const DriverPricing(),
  });

  final ApiClient api;
  final VoidCallback onChanged;
  final DriverPricing initialPricing;

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _baseFare;
  late final TextEditingController _perKm;
  late final TextEditingController _perMinute;
  late final TextEditingController _minimum;

  /// Live preview distance in km, driven by the slider.
  double _previewKm = 10;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  DriverPricing _saved = const DriverPricing();

  @override
  void initState() {
    super.initState();
    _saved = widget.initialPricing;
    _baseFare = TextEditingController(text: _trim(_saved.baseFare));
    _perKm = TextEditingController(text: _trim(_saved.pricePerKm));
    _perMinute = TextEditingController(text: _trim(_saved.pricePerMinute));
    _minimum = TextEditingController(text: _trim(_saved.minimumFare));
    _load();
  }

  @override
  void dispose() {
    _baseFare.dispose();
    _perKm.dispose();
    _perMinute.dispose();
    _minimum.dispose();
    super.dispose();
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Future<void> _load() async {
    try {
      final pricing = await widget.api.fetchDriverPricing();
      if (!mounted) return;
      if (pricing != null) {
        setState(() {
          _saved = pricing;
          _baseFare.text = _trim(pricing.baseFare);
          _perKm.text = _trim(pricing.pricePerKm);
          _perMinute.text = _trim(pricing.pricePerMinute);
          _minimum.text = _trim(pricing.minimumFare);
        });
      }
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your pricing.';
      });
    }
  }

  /// The rate card as currently typed into the form.
  DriverPricing get _draft => DriverPricing(
        baseFare: double.tryParse(_baseFare.text.trim()) ?? 0,
        pricePerKm: double.tryParse(_perKm.text.trim()) ?? 0,
        pricePerMinute: double.tryParse(_perMinute.text.trim()) ?? 0,
        minimumFare: double.tryParse(_minimum.text.trim()) ?? 0,
        currency: _saved.currency,
      );

  bool get _isDirty => _draft != _saved;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final result = await widget.api.updateDriverPricing(pricing: _draft);
      if (!mounted) return;
      if (result == null) {
        _toast('Could not save your pricing.');
        return;
      }
      setState(() {
        _saved = result.pricing;
        _baseFare.text = _trim(result.pricing.baseFare);
        _perKm.text = _trim(result.pricing.pricePerKm);
        _perMinute.text = _trim(result.pricing.pricePerMinute);
        _minimum.text = _trim(result.pricing.minimumFare);
      });
      _toast('Pricing updated.');
      widget.onChanged();
    } catch (_) {
      if (mounted) _toast('Could not save your pricing.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reset() {
    setState(() {
      _baseFare.text = _trim(_saved.baseFare);
      _perKm.text = _trim(_saved.pricePerKm);
      _perMinute.text = _trim(_saved.pricePerMinute);
      _minimum.text = _trim(_saved.minimumFare);
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppTheme.spaceMd),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            AppTheme.spaceLg,
            96,
          ),
          children: [
            _headlineCard(),
            const SizedBox(height: AppTheme.spaceLg),
            _form(),
            const SizedBox(height: AppTheme.spaceLg),
            _previewCard(),
            const SizedBox(height: AppTheme.spaceLg),
            if (_isDirty)
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_rounded),
                label: const Text('Save pricing'),
              ),
          ],
        ),
        if (_saving)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x33000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  /// The per-kilometre rate, front and centre.
  Widget _headlineCard() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final perKm = _draft.pricePerKm;

    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Price per kilometre',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_saved.currency} ${_trim(perKm)}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),
                Text(
                  'per km',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '10 km costs',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${_saved.currency} ${_trim(_draft.quote(distanceMeters: 10000, durationSeconds: 0))}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _form() {
    return Form(
      key: _formKey,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your rate card',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              _moneyField(_perKm, 'Price per kilometre', '25'),
              const SizedBox(height: AppTheme.spaceMd),
              _moneyField(_baseFare, 'Base fare (per trip)', '50'),
              const SizedBox(height: AppTheme.spaceMd),
              _moneyField(_perMinute, 'Price per minute', '3'),
              const SizedBox(height: AppTheme.spaceMd),
              _moneyField(_minimum, 'Minimum fare', '100'),
              const SizedBox(height: AppTheme.spaceMd),
              if (_isDirty)
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('Discard changes'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _moneyField(
    TextEditingController controller,
    String label,
    String hint,
  ) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d{0,7}\.?\d{0,2}')),
      ],
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixText: '${_saved.currency} ',
        prefixStyle: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      onChanged: (_) => setState(() {}),
      validator: (v) {
        final parsed = double.tryParse(v?.trim() ?? '');
        if (parsed == null) return 'Enter a number';
        if (parsed < 0) return 'Cannot be negative';
        if (parsed > 100000) return 'Too large';
        return null;
      },
    );
  }

  /// Live fare preview for an adjustable trip distance.
  Widget _previewCard() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final draft = _draft;
    final quote = draft.quote(
      distanceMeters: _previewKm * 1000,
      durationSeconds: 0,
    );
    final breakdown = draft.breakdown(
      distanceMeters: _previewKm * 1000,
      durationSeconds: 0,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.calculate_rounded, color: scheme.primary),
                const SizedBox(width: AppTheme.spaceSm),
                Expanded(
                  child: Text(
                    'Fare preview',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  '${_trim(_previewKm)} km',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceSm),
            Slider(
              value: _previewKm.clamp(1, 50),
              min: 1,
              max: 50,
              divisions: 49,
              label: '${_previewKm.round()} km',
              onChanged: (v) => setState(() => _previewKm = v),
            ),
            const Divider(height: 1),
            ...breakdown.entries.map(
              (e) => Padding(
                padding: const EdgeInsets.only(top: AppTheme.spaceSm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      '${_saved.currency} ${_trim(e.value)}',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spaceMd,
                vertical: AppTheme.spaceSm,
              ),
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Rider pays for ${_trim(_previewKm)} km',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${_saved.currency} ${_trim(quote)}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
