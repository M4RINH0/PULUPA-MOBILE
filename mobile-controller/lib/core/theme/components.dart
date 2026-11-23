import 'package:material_ui/material_ui.dart';

import 'pulupa_theme.dart';

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: children,
          ),
        ),
      ),
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.color = Colors.white});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: PulupaColors.line),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class StatusLine extends StatelessWidget {
  const StatusLine({
    super.key,
    required this.icon,
    required this.label,
    required this.detail,
    this.alert = false,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: alert ? const Color(0xFFFFECEE) : const Color(0xFFEEF1FF),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              icon,
              size: 20,
              color: alert ? theme.colorScheme.error : PulupaColors.blue,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.titleMedium),
              Text(detail, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
  }
}
