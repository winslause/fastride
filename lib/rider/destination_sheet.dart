import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api_client.dart';
import '../shared/custom_modal.dart';
import '../theme.dart';

/// =========================================================================
/// DestinationSheet
/// -------------------------------------------------------------------------
/// Full-screen address search modal. Three phases:
///   1. Idle — show recent places + saved shortcuts.
///   2. Typing — debounced geocode lookup against Photon / Nominatim.
///   3. Selected — return the chosen `GeocodeResult` to the dashboard.
///
/// The sheet is keyboard-aware: it pushes above the soft keyboard and
/// dismisses with the back gesture or the X button.
/// =========================================================================
class DestinationSheet extends StatefulWidget {
  const DestinationSheet({super.key, required this.api, required this.bias});

  final ApiClient api;

  /// Where to bias search results (current map center).
  final LatLng? bias;

  /// Open as a modal and await the chosen place.
  static Future<GeocodeResult?> show({
    required BuildContext context,
    required ApiClient api,
    LatLng? bias,
  }) {
    return AppSheet.show<GeocodeResult>(
      context: context,
      isScrollControlled: true,
      child: DestinationSheet(api: api, bias: bias),
    );
  }

  @override
  State<DestinationSheet> createState() => _DestinationSheetState();
}

class _DestinationSheetState extends State<DestinationSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  Timer? _debounce;
  CancelToken? _cancel;
  List<GeocodeResult> _results = const [];
  bool _loading = false;
  String? _error;

  /// Saved shortcuts — in a real app these come from local storage
  /// and past trips. Kept here as a design-complete stub.
  static const List<_Shortcut> _shortcuts = [
    _Shortcut('Home', Icons.home_rounded),
    _Shortcut('Work', Icons.work_rounded),
    _Shortcut('Airport', Icons.flight_rounded),
    _Shortcut('Saved place', Icons.bookmark_rounded),
  ];

  @override
  void initState() {
    super.initState();
    // Auto-focus so the keyboard is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final q = _controller.text.trim();
    _debounce?.cancel();

    if (q.length < 3) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }

    _debounce = Timer(AppConstants.searchDebounce, () => _search(q));
  }

  Future<void> _search(String query) async {
    _debounce?.cancel();
    _cancel?.cancel();
    final token = CancelToken();
    _cancel = token;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await widget.api.searchPlaces(
        query: query,
        biasLat: widget.bias?.latitude,
        biasLng: widget.bias?.longitude,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        _error = e.kind == ApiErrorKind.network
            ? 'No internet connection.'
            : e.message;
      });
    } catch (_) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        _error = 'Search failed. Please try again.';
      });
    }
  }

  void _select(GeocodeResult place) {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.size.height * 0.92,
          minHeight: media.size.height * 0.55,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // --- Header ---
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spaceXl,
                AppTheme.spaceSm,
                AppTheme.spaceMd,
                AppTheme.spaceMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Where to?',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // --- Search field ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Search a place or address',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _controller.clear();
                            _focus.requestFocus();
                          },
                        ),
                ),
              ),
            ),

            const SizedBox(height: AppTheme.spaceLg),

            // --- Body ---
            Flexible(child: _body(theme, scheme)),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme, ColorScheme scheme) {
    // Loading bar overlays the content while a request is in flight.
    final showLoading = _loading && _results.isEmpty;

    if (_controller.text.trim().isEmpty) {
      return _buildIdle(theme, scheme);
    }
    if (showLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _buildError(theme, scheme);
    }
    if (_results.isEmpty) {
      return _buildEmpty(theme, scheme);
    }
    return _buildResults(theme, scheme);
  }

  // -------------------------------------------------------------------------
  // Idle — shortcuts
  // -------------------------------------------------------------------------

  Widget _buildIdle(ThemeData theme, ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spaceXl),
      children: [
        SheetSection(
          label: 'Saved places',
          child: Wrap(
            spacing: AppTheme.spaceSm,
            runSpacing: AppTheme.spaceSm,
            children: [
              for (final s in _shortcuts)
                ActionChip(
                  avatar: Icon(s.icon, size: 18, color: scheme.primary),
                  label: Text(s.label),
                  onPressed: () {
                    _controller.text = s.label;
                    _controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: _controller.text.length),
                    );
                    _search(s.label);
                    _focus.requestFocus();
                  },
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spaceXl),
        SheetSection(label: 'Recent', child: _recentPlaceholder(theme, scheme)),
      ],
    );
  }

  Widget _recentPlaceholder(ThemeData theme, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(AppTheme.spaceLg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.spaceMd),
          Expanded(
            child: Text(
              'Your recent trips will appear here.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Results
  // -------------------------------------------------------------------------

  Widget _buildResults(ThemeData theme, ColorScheme scheme) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceXl,
        0,
        AppTheme.spaceXl,
        AppTheme.spaceXl,
      ),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = _results[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.place_rounded, size: 20, color: scheme.primary),
          ),
          title: Text(
            r.primary,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: r.secondary.isEmpty
              ? null
              : Text(
                  r.secondary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: () => _select(r),
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Empty / error
  // -------------------------------------------------------------------------

  Widget _buildEmpty(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppTheme.spaceMd),
          Text(
            'No results found',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTheme.spaceXs),
          Text(
            'Try a different street name or landmark.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(AppTheme.spaceXl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: scheme.error),
          const SizedBox(height: AppTheme.spaceMd),
          Text(
            _error ?? 'Something went wrong',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTheme.spaceLg),
          OutlinedButton.icon(
            onPressed: () => _search(_controller.text.trim()),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _Shortcut {
  const _Shortcut(this.label, this.icon);
  final String label;
  final IconData icon;
}
