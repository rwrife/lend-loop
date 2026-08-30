import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/platform/backup_file_adapter.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class DataPrivacyScreen extends StatefulWidget {
  const DataPrivacyScreen({
    required this.backups,
    required this.files,
    required this.workflow,
    required this.photos,
    this.onDataChanged,
    this.reconcileReminders,
    this.deletePrivateBackupArtifacts,
    super.key,
  });

  final BackupService backups;
  final BackupFileAdapter files;
  final ExchangeWorkflow workflow;
  final PhotoAdapter photos;
  final VoidCallback? onDataChanged;
  final Future<void> Function()? reconcileReminders;
  final Future<void> Function()? deletePrivateBackupArtifacts;

  @override
  State<DataPrivacyScreen> createState() => _DataPrivacyScreenState();
}

class _DataPrivacyScreenState extends State<DataPrivacyScreen> {
  bool _includePhotos = true;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on BackupException catch (error) {
      _message(error.message);
    } on Object {
      _message(
        'The action could not be completed. Check local records and photos before retrying.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _exportBackup() => _run(() async {
    final BackupArtifact artifact = await widget.backups.createBackup(
      includeAttachments: _includePhotos,
    );
    final bool saved = await widget.files.save(
      artifact,
      mimeType: 'application/zip',
    );
    if (saved) _message('ZIP backup saved through the system file picker.');
  });

  Future<void> _exportCsv() => _run(() async {
    final BackupArtifact artifact = await widget.backups.createCsvExport();
    final bool saved = await widget.files.save(artifact, mimeType: 'text/csv');
    if (saved) _message('CSV history saved through the system file picker.');
  });

  Future<void> _restore() => _run(() async {
    final Uint8List? selected = await widget.files.pickBackup();
    if (selected == null || !mounted) return;
    final RestorePreview preview = await widget.backups.previewRestore(
      selected,
    );
    if (!mounted) return;
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Preview restore'),
            content: Text(
              '${preview.adds} new ${preview.adds == 1 ? 'exchange' : 'exchanges'}, '
              '${preview.updates} ${preview.updates == 1 ? 'update' : 'updates'}, and '
              '${preview.conflicts} ${preview.conflicts == 1 ? 'conflict' : 'conflicts'}. '
              '${preview.missingAttachments} attachments are omitted or missing. '
              'Conflicts keep the local record.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirmRestoreButton'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restore'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final RestoreResult result = await widget.backups.applyRestore(preview);
    widget.onDataChanged?.call();
    bool reminderCleanupFailed = false;
    try {
      await widget.reconcileReminders?.call();
    } on Object {
      reminderCleanupFailed = true;
    }
    _message(
      'Restore complete: ${result.added} added, ${result.updated} updated, '
      '${result.conflictsKept} local conflicts kept.'
      '${reminderCleanupFailed ? ' Reminder cleanup failed; retry reminder setup.' : ''}',
    );
  });

  Future<void> _deleteAll() async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete all local data?'),
            content: const Text(
              'This permanently removes every exchange, history event, reminder, '
              'app-private attachment, and automatic pre-restore snapshot from '
              'this device. Export a backup first if you may need the data later.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirmDeleteAllButton'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete everything'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      final List<String> attachments = await widget.workflow
          .allAttachmentPaths();
      bool cleanupFailed = !await widget.photos.deleteWithRollback(
        attachments,
        () async {
          await widget.workflow.deleteAllLocalData();
        },
      );
      try {
        await (widget.deletePrivateBackupArtifacts ??
            widget.backups.deletePrivateBackupArtifacts)();
        // The private-root sweep also clears any staged deletion retry.
        cleanupFailed = false;
      } on Object {
        cleanupFailed = true;
      }
      try {
        await widget.reconcileReminders?.call();
      } on Object {
        cleanupFailed = true;
      }
      widget.onDataChanged?.call();
      _message(
        cleanupFailed
            ? 'All database records were deleted, but some private files or reminders could not be removed.'
            : 'All local records, attachments, and private restore snapshots were deleted.',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data and privacy')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              'Portable exports',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Backups are not encrypted. Anyone with the ZIP can read its records '
              'and included photos. Save and share it only where you trust. Lend Loop '
              'opens the system picker only after you choose an export or restore action.',
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('includePhotosSwitch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Include photos in ZIP backup'),
              subtitle: const Text(
                'Turn this off for a smaller record-only backup.',
              ),
              value: _includePhotos,
              onChanged: _busy
                  ? null
                  : (bool value) => setState(() => _includePhotos = value),
            ),
            FilledButton.icon(
              key: const Key('exportBackupButton'),
              onPressed: _busy ? null : _exportBackup,
              icon: const Icon(Icons.archive_outlined),
              label: const Text('Export ZIP backup'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('exportCsvButton'),
              onPressed: _busy ? null : _exportCsv,
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('Export CSV history'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('restoreBackupButton'),
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.restore_outlined),
              label: const Text('Preview and restore ZIP'),
            ),
            const SizedBox(height: 28),
            Text(
              'Delete local data',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Deleting data affects only this device. Lend Loop has no account, '
              'cloud copy, analytics, or advertising service that retains it.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('deleteAllDataButton'),
              onPressed: _busy ? null : _deleteAll,
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete all local data'),
            ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 16),
              Semantics(liveRegion: true, child: const Text('Working…')),
            ],
          ],
        ),
      ),
    );
  }
}
