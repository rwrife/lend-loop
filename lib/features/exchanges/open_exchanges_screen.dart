import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/features/data/data_privacy_screen.dart';
import 'package:lend_loop/features/exchanges/exchange_details_screen.dart';
import 'package:lend_loop/features/exchanges/record_handoff_screen.dart';
import 'package:lend_loop/platform/backup_file_adapter.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class OpenExchangesScreen extends StatefulWidget {
  const OpenExchangesScreen({
    required this.workflow,
    required this.photoAdapter,
    this.reminderCoordinator,
    this.notificationFeatureMessage,
    this.onRetryNotificationSetup,
    this.backups,
    this.backupFiles,
    super.key,
  });

  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;
  final ReminderCoordinator? reminderCoordinator;
  final String? notificationFeatureMessage;
  final Future<void> Function()? onRetryNotificationSetup;
  final BackupService? backups;
  final BackupFileAdapter? backupFiles;

  @override
  State<OpenExchangesScreen> createState() => _OpenExchangesScreenState();
}

class _OpenExchangesScreenState extends State<OpenExchangesScreen> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _person = TextEditingController();
  ExchangeStatus? _status = ExchangeStatus.open;
  ExchangeDirection? _direction;
  DateTime? _from;
  DateTime? _through;
  late Future<List<ExchangeRecord>> _records;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _records = widget.workflow.search(
      ExchangeSearchFilter(
        text: _search.text,
        personName: _person.text,
        status: _status,
        direction: _direction,
        from: _from,
        through: _through,
      ),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    _person.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) => RecordHandoffScreen(
          workflow: widget.workflow,
          photoAdapter: widget.photoAdapter,
        ),
      ),
    );
    if (mounted) setState(_reload);
  }

  Future<void> _open(ExchangeRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ExchangeDetailsScreen(
          exchangeId: record.exchange.id,
          workflow: widget.workflow,
          photoAdapter: widget.photoAdapter,
          reminderCoordinator: widget.reminderCoordinator,
        ),
      ),
    );
    if (mounted) setState(_reload);
  }

  Future<void> _openDataPrivacy() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DataPrivacyScreen(
          backups: widget.backups!,
          files: widget.backupFiles!,
          workflow: widget.workflow,
          photos: widget.photoAdapter,
          reconcileReminders: widget.reminderCoordinator?.reconcile,
        ),
      ),
    );
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exchanges'),
        actions: <Widget>[
          if (widget.backups != null && widget.backupFiles != null)
            IconButton(
              key: const Key('dataPrivacyButton'),
              tooltip: 'Data and privacy',
              onPressed: _openDataPrivacy,
              icon: const Icon(Icons.security_outlined),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('recordHandoffButton'),
        onPressed: _record,
        icon: const Icon(Icons.add),
        label: const Text('Record handoff'),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.notificationFeatureMessage != null)
              Semantics(
                container: true,
                liveRegion: true,
                explicitChildNodes: true,
                label: widget.notificationFeatureMessage,
                child: widget.onRetryNotificationSetup == null
                    ? Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: ExcludeSemantics(
                            child: Text(widget.notificationFeatureMessage!),
                          ),
                        ),
                      )
                    : MaterialBanner(
                        content: ExcludeSemantics(
                          child: Text(widget.notificationFeatureMessage!),
                        ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: widget.onRetryNotificationSetup,
                            child: const Text('Retry reminder setup'),
                          ),
                        ],
                      ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                children: <Widget>[
                  Semantics(
                    sortKey: OrdinalSortKey(0),
                    child: TextField(
                      key: const Key('searchField'),
                      controller: _search,
                      decoration: const InputDecoration(
                        labelText: 'Search items, people, or notes',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(_reload),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 150,
                          child: Semantics(
                            sortKey: OrdinalSortKey(1),
                            child: TextField(
                              key: const Key('personFilter'),
                              controller: _person,
                              decoration: const InputDecoration(
                                labelText: 'Person',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (_) => setState(_reload),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Semantics(
                          sortKey: OrdinalSortKey(2),
                          child: DropdownButton<ExchangeDirection?>(
                            key: const Key('directionFilter'),
                            value: _direction,
                            hint: const Text('Any direction'),
                            items: const <DropdownMenuItem<ExchangeDirection?>>[
                              DropdownMenuItem(
                                value: null,
                                child: Text('Any direction'),
                              ),
                              DropdownMenuItem(
                                value: ExchangeDirection.lent,
                                child: Text('Lent'),
                              ),
                              DropdownMenuItem(
                                value: ExchangeDirection.borrowed,
                                child: Text('Borrowed'),
                              ),
                            ],
                            onChanged: (ExchangeDirection? value) =>
                                setState(() {
                                  _direction = value;
                                  _reload();
                                }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Semantics(
                          sortKey: OrdinalSortKey(3),
                          child: DropdownButton<ExchangeStatus?>(
                            key: const Key('statusFilter'),
                            value: _status,
                            items: const <DropdownMenuItem<ExchangeStatus?>>[
                              DropdownMenuItem(
                                value: null,
                                child: Text('All history'),
                              ),
                              DropdownMenuItem(
                                value: ExchangeStatus.open,
                                child: Text('Open'),
                              ),
                              DropdownMenuItem(
                                value: ExchangeStatus.returned,
                                child: Text('Returned'),
                              ),
                            ],
                            onChanged: (ExchangeStatus? value) => setState(() {
                              _status = value;
                              _reload();
                            }),
                          ),
                        ),
                        TextButton(
                          onPressed: _chooseDates,
                          child: Text(_from == null ? 'Any date' : 'Date set'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<ExchangeRecord>>(
                future: _records,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<ExchangeRecord>> snapshot,
                    ) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return Center(
                          child: Semantics(
                            label: 'Loading open exchanges',
                            child: const CircularProgressIndicator(),
                          ),
                        );
                      }
                      if (snapshot.hasError) {
                        return _ErrorState(onRetry: () => setState(_reload));
                      }
                      final List<ExchangeRecord> records =
                          snapshot.data ?? <ExchangeRecord>[];
                      if (records.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              _status == ExchangeStatus.returned
                                  ? 'No returned exchanges'
                                  : 'No open exchanges',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      }
                      return RefreshIndicator(
                        onRefresh: () async {
                          setState(_reload);
                          await _records;
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: records.length,
                          separatorBuilder: (BuildContext context, int index) =>
                              const Divider(height: 1),
                          itemBuilder: (BuildContext context, int index) {
                            final ExchangeRecord record = records[index];
                            return Semantics(
                              key: Key('exchange-${record.exchange.id.value}'),
                              button: true,
                              label:
                                  '${_directionSentence(record)}. ${_dueLabel(record)}',
                              hint: 'Open exchange details',
                              excludeSemantics: true,
                              onTap: () => _open(record),
                              child: ListTile(
                                minVerticalPadding: 12,
                                title: Text(_directionSentence(record)),
                                subtitle: Text(_dueLabel(record)),
                                onTap: () => _open(record),
                              ),
                            );
                          },
                        ),
                      );
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseDates() async {
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (range == null || !mounted) return;
    setState(() {
      _from = range.start;
      _through = range.end
          .add(const Duration(days: 1))
          .subtract(const Duration(microseconds: 1));
      _reload();
    });
  }
}

String _directionSentence(ExchangeRecord record) =>
    record.exchange.direction == ExchangeDirection.lent
    ? 'You lent ${record.item.name} to ${record.person.displayName}'
    : 'You borrowed ${record.item.name} from ${record.person.displayName}';

String _dueLabel(ExchangeRecord record) {
  final String status = switch (record.dueState) {
    DueState.overdue => 'Overdue',
    DueState.dueSoon => 'Due soon',
    DueState.upcoming => 'Upcoming',
    DueState.none => 'No due date',
    DueState.returned => 'Returned',
  };
  final DateTime? dueAt = record.exchange.dueAt;
  return dueAt == null ? status : '$status · ${_date(dueAt)}';
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Could not load local records. Your existing data was not changed.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
