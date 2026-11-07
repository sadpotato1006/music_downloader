import 'package:flutter/material.dart';

import '../settings_controller.dart';

/// UI event boundary: persistence failures are shown by SettingsSaveNotice and
/// remain retryable. Callers that need success/failure still receive a result.
Future<bool> runSettingsAction(Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (_) {
    return false;
  }
}

class SettingsSaveNotice extends StatelessWidget {
  const SettingsSaveNotice({super.key, required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<SettingsSaveState>(
        valueListenable: controller.saveState,
        builder: (context, state, _) {
          if (state.error == null) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          return Semantics(
            liveRegion: true,
            child: Container(
              key: const ValueKey('settings-save-error'),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.saving ? '正在重试保存…' : '设置保存失败，修改已保留，请重试。',
                      style: TextStyle(color: colors.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: state.saving ? null : controller.retrySave,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        },
      );
}
