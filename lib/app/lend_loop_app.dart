import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/features/exchanges/open_exchanges_screen.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class LendLoopApp extends StatelessWidget {
  const LendLoopApp({
    required this.workflow,
    required this.photoAdapter,
    super.key,
  });

  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lend Loop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF315C49)),
        useMaterial3: true,
      ),
      home: OpenExchangesScreen(workflow: workflow, photoAdapter: photoAdapter),
    );
  }
}
