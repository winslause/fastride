import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../theme.dart';

/// =========================================================================
/// VehiclesScreen — "manage cars"
/// -------------------------------------------------------------------------
/// The list of vehicles a driver owns, plus add / edit / remove. Every change
/// is written straight to the backend so riders immediately see the right car
/// when a request comes in.
/// =========================================================================
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({
    super.key,
    required this.api,
    required this.onChanged,
    this.initialVehicles = const [],
  });

  final ApiClient api;

  /// Called after any successful mutation so the dashboard can refresh.
  final VoidCallback onChanged;

  final List<VehicleInfo> initialVehicles;

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  List<VehicleInfo> _vehicles = const [];
  bool _loading = true;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _vehicles = widget.initialVehicles;
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
      final vehicles = await widget.api.fetchDriverVehicles();
      if (!mounted) return;
      setState(() {
        _vehicles = vehicles;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your vehicles.';
      });
    }
  }

  Future<void> _save({VehicleInfo? existing}) async {
    final draft = await showModalBottomSheet<VehicleInfo>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _VehicleFormSheet(existing: existing),
    );
    if (draft == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final id = existing?.id;
      if (id == null || id.isEmpty) {
        await widget.api.createDriverVehicle(vehicle: draft);
      } else {
        await widget.api.updateDriverVehicle(vehicleId: id, vehicle: draft);
      }
      if (!mounted) return;
      _toast(existing == null ? 'Vehicle added.' : 'Vehicle updated.');
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) _toast('Could not save that vehicle.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(VehicleInfo vehicle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove vehicle?'),
        content: Text(
          '${vehicle.displayName} (${vehicle.displayPlate}) will be removed from your garage.',
        ),
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
      await widget.api.deleteDriverVehicle(vehicleId: vehicle.id);
      if (!mounted) return;
      _toast('Vehicle removed.');
      await _load();
      widget.onChanged();
    } catch (_) {
      if (mounted) _toast('Could not remove that vehicle.');
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
            if (_vehicles.isEmpty)
              _emptyState()
            else
              ..._vehicles.map((v) => Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.spaceMd),
                    child: _vehicleCard(v),
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
            label: const Text('Add vehicle'),
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
          Icon(Icons.directions_car_outlined, size: 64, color: scheme.primary),
          const SizedBox(height: AppTheme.spaceLg),
          Text('No vehicles yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppTheme.spaceSm),
          Text(
            'Add the car you drive so riders know what to expect.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.spaceXl),
          FilledButton.icon(
            onPressed: () => _save(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add vehicle'),
          ),
        ],
      ),
    );
  }

  Widget _vehicleCard(VehicleInfo v) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: Icon(
                    v.vehicleClass == VehicleClass.moto
                        ? Icons.two_wheeler_rounded
                        : Icons.directions_car_rounded,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: AppTheme.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.displayName,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${v.displayPlate} · ${v.vehicleClass.label}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') _save(existing: v);
                    if (value == 'delete') _delete(v);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Remove')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spaceMd),
            Wrap(
              spacing: AppTheme.spaceSm,
              runSpacing: AppTheme.spaceSm,
              children: [
                _chip(Icons.event_seat_rounded, '${v.seats} seats'),
                _chip(Icons.sell_rounded, v.vehicleClass.description),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
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
/// _VehicleFormSheet — add / edit form
/// =========================================================================
class _VehicleFormSheet extends StatefulWidget {
  const _VehicleFormSheet({this.existing});

  final VehicleInfo? existing;

  @override
  State<_VehicleFormSheet> createState() => _VehicleFormSheetState();
}

class _VehicleFormSheetState extends State<_VehicleFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _make;
  late final TextEditingController _model;
  late final TextEditingController _plate;
  late final TextEditingController _color;
  late final TextEditingController _seats;
  late VehicleClass _vehicleClass;

  @override
  void initState() {
    super.initState();
    final v = widget.existing;
    _make = TextEditingController(text: v?.make ?? '');
    _model = TextEditingController(text: v?.model ?? '');
    _plate = TextEditingController(text: v?.plateNumber ?? '');
    _color = TextEditingController(text: v?.color ?? '');
    _seats = TextEditingController(text: (v?.seats ?? 4).toString());
    _vehicleClass = v?.vehicleClass ?? VehicleClass.standard;
  }

  @override
  void dispose() {
    _make.dispose();
    _model.dispose();
    _plate.dispose();
    _color.dispose();
    _seats.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(
      VehicleInfo(
        id: widget.existing?.id ?? '',
        make: _make.text.trim(),
        model: _model.text.trim(),
        plateNumber: _plate.text.trim(),
        color: _color.text.trim(),
        // Year stays untouched when editing; new vehicles simply don't set it.
        year: widget.existing?.year,
        vehicleClass: _vehicleClass,
        seats: int.tryParse(_seats.text.trim()) ?? 4,
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
                isEdit ? 'Edit vehicle' : 'Add a vehicle',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: AppTheme.spaceLg),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _make,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Make'),
                      validator: _required,
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceMd),
                  Expanded(
                    child: TextFormField(
                      controller: _model,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Model'),
                      validator: _required,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spaceMd),
              TextFormField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Plate number',
                  hintText: 'KDA 123T',
                ),
                validator: _required,
              ),
              const SizedBox(height: AppTheme.spaceMd),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _color,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Colour'),
                    ),
                  ),
                  const SizedBox(width: AppTheme.spaceMd),
                  Expanded(
                    child: TextFormField(
                      controller: _seats,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Seats'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spaceLg),
              Text(
                'Vehicle class',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spaceSm),
              Wrap(
                spacing: AppTheme.spaceSm,
                children: VehicleClass.values.map((c) {
                  return ChoiceChip(
                    label: Text(c.label),
                    selected: _vehicleClass == c,
                    onSelected: (_) => setState(() => _vehicleClass = c),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppTheme.spaceXl),
              FilledButton.icon(
                onPressed: _submit,
                icon: Icon(isEdit ? Icons.save_rounded : Icons.add_rounded),
                label: Text(isEdit ? 'Save changes' : 'Add vehicle'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _required(String? value) =>
      (value == null || value.trim().isEmpty) ? 'Required' : null;
}
