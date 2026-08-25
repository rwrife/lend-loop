import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/features/exchanges/exchange_details_screen.dart';
import 'package:lend_loop/features/exchanges/record_handoff_screen.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class OpenExchangesScreen extends StatefulWidget {
  const OpenExchangesScreen({
    required this.workflow,
    required this.photoAdapter,
    super.key,
  });

  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;

  @override
  State<OpenExchangesScreen> createState() => _OpenExchangesScreenState();
}

class _OpenExchangesScreenState extends State<OpenExchangesScreen> {
  OpenExchangeFilter _filter = OpenExchangeFilter.all;
  late Future<List<ExchangeRecord>> _records;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _records = widget.workflow.openExchanges(filter: _filter);
  }

  void _setFilter(OpenExchangeFilter filter) {
    setState(() {
      _filter = filter;
      _reload();
    });
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
        ),
      ),
    );
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exchanges')),
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
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: SegmentedButton<OpenExchangeFilter>(
                segments: const <ButtonSegment<OpenExchangeFilter>>[
                  ButtonSegment<OpenExchangeFilter>(
                    value: OpenExchangeFilter.all,
                    label: Text('All open'),
                  ),
                  ButtonSegment<OpenExchangeFilter>(
                    value: OpenExchangeFilter.dueSoon,
                    label: Text('Due soon'),
                  ),
                  ButtonSegment<OpenExchangeFilter>(
                    value: OpenExchangeFilter.overdue,
                    label: Text('Overdue'),
                  ),
                  ButtonSegment<OpenExchangeFilter>(
                    value: OpenExchangeFilter.returned,
                    label: Text('Returned'),
                  ),
                ],
                selected: <OpenExchangeFilter>{_filter},
                onSelectionChanged: (Set<OpenExchangeFilter> selected) {
                  _setFilter(selected.single);
                },
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
                              _filter == OpenExchangeFilter.returned
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
                            return ListTile(
                              minVerticalPadding: 12,
                              title: Text(_directionSentence(record)),
                              subtitle: Text(_dueLabel(record)),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(record),
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
