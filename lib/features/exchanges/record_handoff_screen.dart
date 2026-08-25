import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class RecordHandoffScreen extends StatefulWidget {
  const RecordHandoffScreen({
    required this.workflow,
    required this.photoAdapter,
    this.initialHandoffAt,
    this.initialDueAt,
    super.key,
  });

  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;
  final DateTime? initialHandoffAt;
  final DateTime? initialDueAt;

  @override
  State<RecordHandoffScreen> createState() => _RecordHandoffScreenState();
}

class _RecordHandoffScreenState extends State<RecordHandoffScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _item = TextEditingController();
  final TextEditingController _person = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  ExchangeDirection _direction = ExchangeDirection.lent;
  late DateTime _handoffAt;
  DateTime? _dueAt;
  PhotoPickResult? _photo;
  String? _photoMessage;
  String? _dateError;
  String? _storageError;
  bool _saving = false;
  bool _photoCommitted = false;

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    _handoffAt =
        widget.initialHandoffAt ?? DateTime(now.year, now.month, now.day);
    _dueAt = widget.initialDueAt;
  }

  @override
  void dispose() {
    if (!_photoCommitted && _photo?.relativePath != null) {
      unawaited(widget.photoAdapter.discard(_photo!.relativePath!));
    }
    _item.dispose();
    _person.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool due}) async {
    final DateTime initial = due ? (_dueAt ?? _handoffAt) : _handoffAt;
    final DateTime? selected = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDate: initial,
      helpText: due ? 'Choose due date' : 'Choose handoff date',
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (due) {
        _dueAt = selected;
      } else {
        _handoffAt = selected;
      }
      _dateError = null;
    });
  }

  Future<void> _addPhoto() async {
    final PhotoPickResult result = await widget.photoAdapter.pickPhoto();
    if (!mounted) return;
    if (_photo?.relativePath != null &&
        _photo!.relativePath != result.relativePath) {
      await widget.photoAdapter.discard(_photo!.relativePath!);
    }
    setState(() {
      _photo = result.status == PhotoPickStatus.selected ? result : null;
      _photoMessage = switch (result.status) {
        PhotoPickStatus.selected => 'Photo ready to save.',
        PhotoPickStatus.cancelled =>
          'No photo selected. You can continue without one.',
        PhotoPickStatus.denied =>
          'Photo access was denied. You can still save a text-only record.',
      };
    });
  }

  bool _validate() {
    final bool fieldsValid = _formKey.currentState?.validate() ?? false;
    final bool datesValid = _dueAt == null || !_dueAt!.isBefore(_handoffAt);
    setState(() {
      _dateError = datesValid
          ? null
          : 'Due date must be on or after the handoff date.';
    });
    return fieldsValid && datesValid;
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!_validate()) return;
    setState(() {
      _saving = true;
      _storageError = null;
    });
    try {
      final PhotoPickResult? photo = _photo;
      await widget.workflow.recordHandoff(
        HandoffDraft(
          direction: _direction,
          itemName: _item.text,
          personName: _person.text,
          handedOffAt: _handoffAt,
          dueAt: _dueAt,
          notes: _notes.text,
        ),
        attachment: photo == null
            ? null
            : AttachmentDraft(
                relativePath: photo.relativePath!,
                mediaType: photo.mediaType!,
                byteSize: photo.byteSize!,
                digest: photo.digest!,
              ),
      );
      _photoCommitted = photo != null;
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _storageError =
              'Could not save this handoff. Check local storage and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Record handoff')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              const Text('Direction'),
              const SizedBox(height: 8),
              SegmentedButton<ExchangeDirection>(
                segments: const <ButtonSegment<ExchangeDirection>>[
                  ButtonSegment<ExchangeDirection>(
                    value: ExchangeDirection.lent,
                    label: Text('Lent'),
                    icon: Icon(Icons.north_east),
                  ),
                  ButtonSegment<ExchangeDirection>(
                    value: ExchangeDirection.borrowed,
                    label: Text('Borrowed'),
                    icon: Icon(Icons.south_west),
                  ),
                ],
                selected: <ExchangeDirection>{_direction},
                onSelectionChanged: (Set<ExchangeDirection> value) {
                  setState(() => _direction = value.single);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('itemNameField'),
                controller: _item,
                decoration: const InputDecoration(
                  labelText: 'Item name',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                validator: (String? value) =>
                    value == null || value.trim().isEmpty
                    ? 'Item name is required.'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('personNameField'),
                controller: _person,
                decoration: const InputDecoration(
                  labelText: 'Person alias',
                  helperText:
                      'Stored only on this device. Contacts are not accessed.',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                validator: (String? value) =>
                    value == null || value.trim().isEmpty
                    ? 'Person alias is required.'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('notesField'),
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                ),
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: 16),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Handoff date',
                  border: OutlineInputBorder(),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text(_formatDate(_handoffAt))),
                    TextButton(
                      onPressed: () => _pickDate(due: false),
                      child: const Text('Change'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Due date (optional)',
                  errorText: _dateError,
                  border: const OutlineInputBorder(),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _dueAt == null ? 'No due date' : _formatDate(_dueAt!),
                      ),
                    ),
                    if (_dueAt != null)
                      IconButton(
                        tooltip: 'Clear due date',
                        onPressed: () => setState(() => _dueAt = null),
                        icon: const Icon(Icons.clear),
                      ),
                    TextButton(
                      onPressed: () => _pickDate(due: true),
                      child: Text(_dueAt == null ? 'Add' : 'Change'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('addPhotoButton'),
                onPressed: _addPhoto,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(
                  _photo == null ? 'Add optional photo' : 'Change photo',
                ),
              ),
              if (_photoMessage != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_photoMessage!),
                  ),
                ),
              if (_storageError != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _storageError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('saveHandoffButton'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving' : 'Save handoff'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
