import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// =========================================================================
/// AppSheet
/// -------------------------------------------------------------------------
/// The single blueprint for every bottom sheet in the app.
///
/// Why a wrapper instead of raw `showModalBottomSheet`?
/// 1. Guarantees identical corner radii, drag handle, and safe-area padding
///    across every sheet — a huge part of "premium feel".
/// 2. Centralises the keyboard-avoidance strategy (critical for input sheets).
/// 3. Provides a consistent close affordance (swipe-down + optional X button).
/// 4. Exposes an `AppSheet.show(...)` static so callers never touch the
///    raw Flutter API — swapping the animation later touches one file.
/// =========================================================================
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.showCloseButton = true,
    this.isScrollControlled = true,
    this.initialChildSize,
    this.padding,
    this.footer,
    this.leading,
  });

  /// Sheet body — usually a Column or a scrollable list.
  final Widget child;

  /// Optional headline shown in the header row.
  final String? title;

  /// Optional supporting line beneath the title.
  final String? subtitle;

  /// Show the little circular X on the top-right.
  final bool showCloseButton;

  /// Allow the sheet to grow taller than half the screen (needed for lists).
  final bool isScrollControlled;

  /// Starting height fraction when `isScrollControlled` is true.
  final double? initialChildSize;

  /// Override the inner padding (defaults to 20/16).
  final EdgeInsetsGeometry? padding;

  /// Optional sticky footer widget (e.g. a primary CTA).
  final Widget? footer;

  /// Optional leading widget in the header (usually an icon).
  final Widget? leading;

  // -------------------------------------------------------------------------
  // Public API — always open sheets through this.
  // -------------------------------------------------------------------------
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget child,
    bool isDismissible = true,
    bool enableDrag = true,
    bool isScrollControlled = true,
    Color? barrierColor,
  }) {
    // Guard against calling show() after the widget tree is torn down —
    // a common source of crashes on slow devices.
    if (!context.mounted) return Future<T?>.value();

    return showModalBottomSheet<T>(
      context: context,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      isScrollControlled: isScrollControlled,
      useSafeArea: true,
      useRootNavigator: true,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      barrierColor: barrierColor ??
          Theme.of(context).bottomSheetTheme.modalBarrierColor ??
          Colors.black.withValues(alpha: 0.45),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLg),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);

    // Keyboard-aware padding: pushes the sheet above the soft keyboard
    // without jumping. Critical for the address-search sheet.
    final keyboardInset = media.viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.size.height * (initialChildSize ?? 0.92),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // --- Header (drag handle is added by theme, so we skip it) ---
            if (title != null || showCloseButton || leading != null)
              _Header(
                title: title,
                subtitle: subtitle,
                leading: leading,
                showCloseButton: showCloseButton,
              ),

            // --- Body ---
            Flexible(
              child: Padding(
                padding: padding ??
                    const EdgeInsets.fromLTRB(
                      AppTheme.spaceXl,
                      0,
                      AppTheme.spaceXl,
                      AppTheme.spaceXl,
                    ),
                child: child,
              ),
            ),

            // --- Optional sticky footer ---
            if (footer != null)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTheme.spaceXl,
                      AppTheme.spaceLg,
                      AppTheme.spaceXl,
                      AppTheme.spaceLg,
                    ),
                    child: footer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header — internal, not exported.
// ---------------------------------------------------------------------------
class _Header extends StatelessWidget {
  const _Header({
    this.title,
    this.subtitle,
    this.leading,
    this.showCloseButton = true,
  });

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spaceXl,
        AppTheme.spaceSm,
        AppTheme.spaceMd,
        AppTheme.spaceMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppTheme.spaceMd),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (showCloseButton)
            IconButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                Navigator.of(context).maybePop();
              },
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
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
    );
  }
}

/// =========================================================================
/// SheetSection
/// -------------------------------------------------------------------------
/// A small labelled grouping primitive for use inside sheets.
/// Keeps spacing and label hierarchy consistent without inventing new styles.
/// =========================================================================
class SheetSection extends StatelessWidget {
  const SheetSection({
    super.key,
    this.label,
    required this.child,
    this.spacing = AppTheme.spaceMd,
  });

  final String? label;
  final Widget child;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(
            label!.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(height: spacing),
        ],
        child,
      ],
    );
  }
}

/// =========================================================================
/// SheetPrimaryButton
/// -------------------------------------------------------------------------
/// A full-width primary CTA tuned for sheet footers (56px tall,
/// auto-disables on tap when `onPressed` is null).
/// =========================================================================
class SheetPrimaryButton extends StatelessWidget {
  const SheetPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.tone = SheetButtonTone.primary,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final SheetButtonTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (bg, fg) = switch (tone) {
      SheetButtonTone.primary => (scheme.primary, scheme.onPrimary),
      SheetButtonTone.danger => (AppTheme.danger, Colors.white),
      SheetButtonTone.neutral => (scheme.surfaceContainerHigh, scheme.onSurface),
    };

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: (isLoading || onPressed == null)
            ? null
            : () {
                HapticFeedback.lightImpact();
                onPressed!();
              },
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: bg.withValues(alpha: 0.5),
          disabledForegroundColor: fg.withValues(alpha: 0.7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
        child: isLoading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: fg,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20),
                    const SizedBox(width: AppTheme.spaceSm),
                  ],
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

enum SheetButtonTone { primary, danger, neutral }