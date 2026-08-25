import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class ExchangeDetailsScreen extends StatefulWidget {
  const ExchangeDetailsScreen({
    required this.exchangeId,
    required this.workflow,
    required this.photoAdapter,
    super.key,
  });

  final ExchangeId exchangeId;
  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;

  @override
  State<ExchangeDetailsScreen> createState() => _ExchangeDetailsScreenState();
}

class _ExchangeDetailsScreenState extends State<ExchangeDetailsScreen> {
  late Future<ExchangeRecord> _record;

  @override
  void initState() {
    super.initState();
    _record = widget.workflow.details(widget.exchangeId);
  }

  Future<void> _return() async {
    try {
      final ExchangeRecord returned = await widget.workflow.markReturned(
        widget.exchangeId,
      );
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
              if (record.item.description != null) ...<Widget>[
                const SizedBox(height: 16),
                Text('Notes', style: Theme.of(context).textTheme.titleMedium),
                Text(record.item.description!),
              ],
              const SizedBox(height: 20),
              Text('Photo', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _PhotoPanel(record: record, adapter: widget.photoAdapter),
              const SizedBox(height: 24),
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
            ],
          );
        },
      ),
    );
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
