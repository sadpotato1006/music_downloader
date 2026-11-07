import 'package:flutter/material.dart';

/// Rebuilds for changes to a selected immutable value, not every notification.
class SelectedBuilder<T> extends StatefulWidget {
  const SelectedBuilder({
    super.key,
    required this.listenable,
    required this.select,
    required this.builder,
    this.child,
  });
  final Listenable listenable;
  final T Function() select;
  final Widget Function(BuildContext, Widget?) builder;
  final Widget? child;

  @override
  State<SelectedBuilder<T>> createState() => _SelectedBuilderState<T>();
}

class _SelectedBuilderState<T> extends State<SelectedBuilder<T>> {
  late T _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.select();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant SelectedBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _selected = widget.select();
  }

  void _changed() {
    final next = widget.select();
    if (next == _selected) return;
    setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }
}
