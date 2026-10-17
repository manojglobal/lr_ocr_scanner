import 'package:flutter/material.dart';

/// Rationale dialog shown when a required runtime permission (Camera/Gallery) is denied.
class PermissionRationaleDialog extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final bool isPermanent;
  final VoidCallback onRetryOrSettings;

  const PermissionRationaleDialog({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.security,
    this.isPermanent = false,
    required this.onRetryOrSettings,
  });

  static Future<void> show({
    required BuildContext context,
    required String title,
    required String message,
    IconData icon = Icons.security,
    bool isPermanent = false,
    required VoidCallback onRetryOrSettings,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => PermissionRationaleDialog(
        title: title,
        message: message,
        icon: icon,
        isPermanent: isPermanent,
        onRetryOrSettings: onRetryOrSettings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
      title: Text(title, textAlign: TextAlign.center),
      content: Text(
        message,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      actionsAlignment: MainAxisAlignment.spaceEvenly,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            onRetryOrSettings();
          },
          icon: Icon(isPermanent ? Icons.settings : Icons.refresh),
          label: Text(isPermanent ? 'Open Settings' : 'Try Again'),
        ),
      ],
    );
  }
}
