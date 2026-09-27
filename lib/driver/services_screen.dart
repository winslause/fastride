import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../models/driver_model.dart';
import '../theme.dart';

/// =========================================================================
/// ServicesScreen
/// -------------------------------------------------------------------------
/// The extras a driver offers on top of a normal ride — airport transfers,
/// luggage space, hourly hire, and so on. Riders see these when requesting.
/// =========================================================================
class ServicesScreen extends StatefulWidget {
  const ServicesScreen({
    super.key,
    required this.api,
    required this.onChanged,
    this.initialServices = const [],
  });

  final ApiClient api;
  final VoidCallback onChanged;
  final List<DriverService> initialServices;

  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  List<DriverService> _services = const [];
  bool _loading = true;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _services = widget.initialServices;
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final services = await widget.api.fetchDriverServices();
      if (!mounted) return;
      setState(() {
        _services = services;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your services.';
      });
    }
  }

  Future<void> _save({DriverService? existing}) async {
    final draft = await showModalBottomSheet<DriverService>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ServiceFormSheet(existing: existing),
    );
    if (draft == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final id = existing?.id;
      if (id == null || id.isEmpty) {
        await widget.api.createDriverService(service: draft);
      } else {
        await widget.api.updateDriverService(serviceId: id, service: draft);
      }
      if (!mounted) return;
      _toast(existing == null ? 'Service added.' : 'Service updated.');
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) _toast('Could not save that service.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleActive(DriverService service) async {
    final updated = service.copyWith(isActive: !service.isActive);
    setState(() => _saving = true);
    try {
      await widget.api.updateDriverService(
        serviceId: service.id,
        service: updated,
      );
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) _toast('Could not update that service.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(DriverService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove service?'),
        content: Text('"${service.name}" will no longer be offered.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await widget.api.deleteDriverService(serviceId: service.id);
      if (!mounted) return;
      _toast('Service removed.');
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) _toast('Could not remove that service.');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
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
            if (_services.isEmpty)
              _emptyState()
            else
              ..._services.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.spaceMd),
                    child: _serviceCard(s),
                  )),
          ],
        ),
        Positioned(
          right: AppTheme.spaceLg,
          bottom: AppTheme.spaceLg,
          child: FloatingActionButton.extended(
            onPressed: _saving ? null : () => _save(),
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add service'),
          ),
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

  Widget _emptyState() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.space2xl),
      child: Column(
        children: [
          Icon(Icons.local_offer_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: AppTheme.spaceLg),
          Text('No services yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            'Offer extras like airport transfers or extra luggage space to earn more per trip.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spaceXl),
          FilledButton.icon(
            onPressed: () => _save(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add service'),
          ),
        ],
      ),
    );
  }

  Widget _serviceCard(DriverService s) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Opacity(
      opacity: s.isActive ? 1 : 0.55,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spaceLg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Icon(s.iconData, color: scheme.primary),
              ),
              const SizedBox(width: AppTheme.spaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if ((s.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        s.description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppTheme.spaceSm),
                    Wrap(
                      spacing: AppTheme.spaceSm,
                      runSpacing: AppTheme.spaceSm,
                      children: [
                        if (s.priceLabel != null)
                          _pill(Icons.sell_rounded, s.priceLabel!),
                        if (s.durationLabel != null)
                          _pill(Icons.schedule_rounded, s.durationLabel!),
                        _pill(
                          s.isActive
                              ? Icons.check_circle_rounded
                              : Icons.pause_circle_rounded,
                          s.isActive ? 'Active' : 'Paused',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Switch(
                    value: s.isActive,
                    onChanged: (_) => _toggleActive(s),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') _save(existing: s);
                      if (value == 'delete') _delete(s);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Remove')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

/// =========================================================================
/// _ServiceFormSheet
/// =========================================================================
class _ServiceFormSheet extends StatefulWidget {
  const _ServiceFormSheet({this.existing});

  final DriverService? existing;

  @override
  State<_ServiceFormSheet> createState() => _ServiceFormSheetState();
}

class _ServiceFormSheetState extends State<_ServiceFormSheet> {
  static const _icons = <String, String>{
    'airport': 'Airport transfer',
    'luggage': 'Extra luggage',
    'pet': 'Pet friendly',
    'hourly': 'Hourly hire',
    'boda': 'Motorbike ride',
    'ac': 'Air conditioned',
    'wifi': 'Wi-Fi',
    'child_seat': 'Child seat',
  };

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _price;
  late final TextEditingController _duration;
  late String _icon;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _name = TextEditingController(text: s?.name ?? '');
    _description = TextEditingController(text: s?.description ?? '');
    _price = TextEditingController(text: s?.price?.toString() ?? '');
    _duration =
        TextEditingController(text: s?.durationMinutes?.toString() ?? '');
    _icon = s?.icon ?? 'airport';
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _price.dispose();
    _duration.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(
      DriverService(
        id: widget.existing?.id ?? '',
        name: _name.text.trim(),
        description: _description.text.trim(),
        price: double.tryParse(_price.text.trim()),
        currency: widget.existing?.currency ?? 'KES',
        durationMinutes: int.tryParse(_duration.text.trim()),
        icon: _icon,
        isActive: widget.existing?.isActive ?? true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEdit = widget.existing != null;

    return Padding(
      padding: EdgeInsets.only(
        left: AppTheme.spaceLg,
        right: AppTheme.spaceLg,
        top: AppTheme.spaceLg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppTheme.spaceLg,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isEdit ? 'Edit service' : 'Add a service',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Service name',
                  hintText: 'Airport transfer',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Give the service a name'
                    : null,
              ),
              const SizedBox(height: AppTheme.spaceMd),
              TextFormField(
                controller: _description,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Up to 3 bags, waiting time included',
                ),
              ),
              const SizedBox(height: AppTheme.spaceMd),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _price,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Extra price',
                        hintText: '0.00',
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        final parsed = double.tryParse(v.trim());
                        if (parsed == null) return 'Use a number';
                        if (parsed < 0) return 'Cannot be negative';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceMd),
                  Expanded(
                    child: TextFormField(
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Extra minutes',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spaceLg),
              Text('Icon', style: theme.textTheme.labelLarge),
              const SizedBox(height: AppTheme.spaceSm),
              Wrap(
                spacing: AppTheme.spaceSm,
                runSpacing: AppTheme.spaceSm,
                children: _icons.entries.map((e) {
                  return ChoiceChip(
                    avatar: Icon(
                      DriverService(id: '', name: '', icon: e.key).iconData,
                      size: 16,
                    ),
                    label: Text(e.value),
                    selected: _icon == e.key,
                    onSelected: (_) => setState(() => _icon = e.key),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppTheme.spaceXl),
              FilledButton.icon(
                onPressed: _submit,
                icon: Icon(isEdit ? Icons.save_rounded : Icons.add_rounded),
                label: Text(isEdit ? 'Save changes' : 'Add service'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
