import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class ExchangeDetailsScreen extends StatefulWidget {
  const ExchangeDetailsScreen({
    required this.exchangeId,
    required this.workflow,
    required this.photoAdapter,
    this.reminderCoordinator,
    super.key,
  });

  final ExchangeId exchangeId;
  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;
  final ReminderCoordinator? reminderCoordinator;

  @override
  State<ExchangeDetailsScreen> createState() => _ExchangeDetailsScreenState();
}

class _ExchangeDetailsScreenState extends State<ExchangeDetailsScreen> {
  late Future<ExchangeRecord> _record;
  String? _reminderDeliveryStatus;
  bool _reminderDeliveryPending = false;

  @override
  void initState() {
    super.initState();
    _record = widget.workflow.details(widget.exchangeId);
    unawaited(_loadReminderDeliveryState());
  }

  Future<void> _loadReminderDeliveryState() async {
    final Reminder? reminder = await widget.reminderCoordinator?.reminder(
      widget.exchangeId,
    );
    if (!mounted || reminder?.deliveryState != ReminderDeliveryState.pending) {
      return;
    }
    setState(() {
      _reminderDeliveryPending = true;
      _reminderDeliveryStatus =
          'Reminder saved, but delivery is pending. Retry reminder delivery.';
    });
  }

  Future<void> _return() async {
    try {
      final ExchangeRecord returned = await widget.workflow.markReturned(
        widget.exchangeId,
      );
      try {
        await widget.reminderCoordinator?.reconcile();
      } on Object {
        // The return and authoritative reminder deletion already committed.
      }
      if (!mounted) return;
      setState(() {
        _record = Future<ExchangeRecord>.value(returned);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Marked returned'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'Undo', onPressed: _undo),
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not mark this exchange returned.'),
          ),
        );
      }
    }
  }

  Future<void> _undo() async {
    try {
      final ExchangeRecord reopened = await widget.workflow.reopen(
        widget.exchangeId,
      );
      if (mounted) {
        setState(() {
          _record = Future<ExchangeRecord>.value(reopened);
        });
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not undo the return.')),
        );
      }
    }
  }

  Future<void> _reopen() async {
    try {
      final ExchangeRecord reopened = await widget.workflow.reopen(
        widget.exchangeId,
      );
      if (mounted) {
        setState(() {
          _record = Future<ExchangeRecord>.value(reopened);
        });
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reopen this exchange.')),
        );
      }
    }
  }

  Future<void> _deletePhoto(ExchangeRecord record) async {
    final Attachment attachment = record.attachments.first;
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete this photo?'),
            content: const Text(
              'The exchange and its text history will remain on this device.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirmDeletePhotoButton'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete photo'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    bool cleanupComplete;
    try {
      cleanupComplete = await widget.photoAdapter.deleteWithRollback(<String>[
        attachment.relativePath,
      ], () async => widget.workflow.deleteAttachment(attachment.id));
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete this photo record.')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _record = widget.workflow.details(widget.exchangeId);
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cleanupComplete ? 'Photo deleted. The text record remains.' : 'The photo record was deleted, but its private file could not be removed.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteExchange() async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete this exchange?'),
            content: const Text(
              'This permanently removes the exchange, its complete event history, '
              'reminder, and attachments from this device.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirmDeleteExchangeButton'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete exchange'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final ExchangeRecord record;
    try {
      record = await widget.workflow.details(widget.exchangeId);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete this exchange.')),
        );
      }
      return;
    }

    bool cleanupFailed;
    try {
      cleanupFailed = !await widget.photoAdapter.deleteWithRollback(
        record.attachments.map((Attachment value) => value.relativePath),
        () async => widget.workflow.deleteExchange(widget.exchangeId),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not delete this exchange.')),
        );
      }
      return;
    }
    try {
      await widget.reminderCoordinator?.reconcile();
    } on Object {
      cleanupFailed = true;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleanupFailed
              ? 'Exchange deleted, but some device cleanup could not be completed.'
              : 'Exchange and its local data were deleted.',
        ),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exchange details')),
      body: FutureBuilder<ExchangeRecord>(
        future: _record,
        builder: (BuildContext context, AsyncSnapshot<ExchangeRecord> snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || snapshot.data == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'This exchange could not be loaded. It may no longer exist.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final ExchangeRecord record = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text(
                _directionSentence(record),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              Text(
                'Status: ${record.exchange.status == ExchangeStatus.open ? 'Open' : 'Returned'}',
              ),
              Text('Handoff date: ${_formatDate(record.exchange.handedOffAt)}'),
              Text(
                record.exchange.dueAt == null
                    ? 'Due date: None'
                    : 'Due date: ${_formatDate(record.exchange.dueAt!)}',
              ),
              if (record.exchange.status == ExchangeStatus.open)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('editDueDateButton'),
                    onPressed: () => _editDueDate(record),
                    icon: const Icon(Icons.edit_calendar_outlined),
                    label: const Text('Edit due date'),
                  ),
                ),
              if (record.item.description != null) ...<Widget>[
                const SizedBox(height: 16),
                Text('Notes', style: Theme.of(context).textTheme.titleMedium),
                Text(record.item.description!),
              ],
              const SizedBox(height: 20),
              Text('Photo', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _PhotoPanel(record: record, adapter: widget.photoAdapter),
              if (record.attachments.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('deletePhotoButton'),
                    onPressed: () => _deletePhoto(record),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete photo'),
                  ),
                ),
              const SizedBox(height: 24),
              if (record.exchange.status == ExchangeStatus.open &&
                  record.exchange.dueAt != null &&
                  record.dueState != DueState.overdue &&
                  widget.reminderCoordinator != null) ...<Widget>[
                if (_reminderDeliveryStatus != null) ...<Widget>[
                  Semantics(
                    container: true,
                    liveRegion: true,
                    label: _reminderDeliveryStatus,
                    child: ExcludeSemantics(
                      child: Text(_reminderDeliveryStatus!),
                    ),
                  ),
                  if (_reminderDeliveryPending)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const Key('retryReminderDeliveryButton'),
                        onPressed: _retryReminderDelivery,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry reminder delivery'),
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  key: const Key('enableReminderButton'),
                  onPressed: () => _enableReminder(record),
                  icon: const Icon(Icons.notifications_outlined),
                  label: const Text('Enable due reminder'),
                ),
                const SizedBox(height: 12),
              ],
              if (record.exchange.status == ExchangeStatus.open)
                FilledButton.icon(
                  key: const Key('markReturnedButton'),
                  onPressed: _return,
                  icon: const Icon(Icons.assignment_turned_in_outlined),
                  label: const Text('Mark returned'),
                )
              else
                FilledButton.icon(
                  key: const Key('reopenButton'),
                  onPressed: _reopen,
                  icon: const Icon(Icons.undo),
                  label: const Text('Reopen exchange'),
                ),
              const SizedBox(height: 24),
              Text('History', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final ExchangeEvent event in record.events)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(_eventLabel(event.type)),
                  subtitle: Text(_formatDateTime(event.occurredAt)),
                ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                key: const Key('deleteExchangeButton'),
                onPressed: _deleteExchange,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Delete exchange'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _enableReminder(ExchangeRecord record) async {
    final ReminderEnableResult result = await widget.reminderCoordinator!
        .enable(
          exchangeId: record.exchange.id,
          itemName: record.item.name,
          personName: record.person.displayName,
          scheduledAt: record.exchange.dueAt!,
        );
    if (!mounted) return;
    if (result == ReminderEnableResult.savedDeliveryPending) {
      setState(() {
        _reminderDeliveryPending = true;
        _reminderDeliveryStatus =
            'Reminder saved, but delivery is pending. Retry reminder delivery.';
      });
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (result) {
          ReminderEnableResult.enabled =>
            'Reminder enabled for ${_formatDate(record.exchange.dueAt!)}.',
          ReminderEnableResult.savedDeliveryPending => throw StateError(
            'Handled as persistent status.',
          ),
          ReminderEnableResult.denied =>
            'Notifications are off. Your exchange is still available.',
        }),
      ),
    );
  }

  Future<void> _retryReminderDelivery() async {
    try {
      await widget.reminderCoordinator!.reconcile();
      if (!mounted) return;
      setState(() {
        _reminderDeliveryPending = false;
        _reminderDeliveryStatus = 'Reminder delivery restored.';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _reminderDeliveryPending = true;
        _reminderDeliveryStatus =
            'Retry failed. Reminder delivery is still pending.';
      });
    }
  }

  Future<void> _editDueDate(ExchangeRecord record) async {
    final DateTime? selected = await showDatePicker(
      context: context,
      firstDate: record.exchange.handedOffAt,
      lastDate: DateTime(2100),
      initialDate: record.exchange.dueAt ?? record.exchange.handedOffAt,
      helpText: 'Choose due date',
    );
    if (selected == null || !mounted) return;
    try {
      final ExchangeRecord edited = await widget.workflow.editDueDate(
        widget.exchangeId,
        selected,
      );
      final ReminderUpdateResult? reminderResult = await widget
          .reminderCoordinator
          ?.update(
            exchangeId: edited.exchange.id,
            itemName: edited.item.name,
            personName: edited.person.displayName,
            scheduledAt: selected,
          );
      if (mounted) {
        setState(() {
          _record = Future<ExchangeRecord>.value(edited);
          if (reminderResult == ReminderUpdateResult.savedDeliveryPending) {
            _reminderDeliveryPending = true;
            _reminderDeliveryStatus =
                'Due date saved, but reminder delivery is pending. '
                'Retry reminder delivery.';
          } else if (reminderResult == ReminderUpdateResult.updated) {
            _reminderDeliveryPending = false;
            _reminderDeliveryStatus = 'Due date and reminder updated.';
          }
        });
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update the due date.')),
        );
      }
    }
  }
}

class _PhotoPanel extends StatelessWidget {
  const _PhotoPanel({required this.record, required this.adapter});

  final ExchangeRecord record;
  final PhotoAdapter adapter;

  @override
  Widget build(BuildContext context) {
    if (record.attachments.isEmpty) return const Text('No photo attached');
    final Attachment attachment = record.attachments.first;
    return FutureBuilder<String?>(
      future: adapter.resolve(attachment.relativePath),
      builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LinearProgressIndicator();
        }
        final String? path = snapshot.data;
        if (path == null) {
          return const Text(
            'Photo unavailable on this device. The text record is still usable.',
          );
        }
        return Semantics(
          label: 'Photo of ${record.item.name}',
          image: true,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(path),
              height: 220,
              fit: BoxFit.cover,
              errorBuilder:
                  (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) => const Text(
                    'Photo unavailable on this device. The text record is still usable.',
                  ),
            ),
          ),
        );
      },
    );
  }
}

String _directionSentence(ExchangeRecord record) =>
    record.exchange.direction == ExchangeDirection.lent
    ? 'You lent ${record.item.name} to ${record.person.displayName}'
    : 'You borrowed ${record.item.name} from ${record.person.displayName}';

String _eventLabel(ExchangeEventType type) => switch (type) {
  ExchangeEventType.created => 'Recorded',
  ExchangeEventType.edited => 'Edited',
  ExchangeEventType.reminded => 'Reminder updated',
  ExchangeEventType.returned => 'Returned',
  ExchangeEventType.reopened => 'Reopened',
};

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _formatDateTime(DateTime value) =>
    '${_formatDate(value)} '
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
