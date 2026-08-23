import 'package:flutter/material.dart';
import 'package:lend_loop/app/development_status.dart';

class DevelopmentScreen extends StatelessWidget {
  const DevelopmentScreen({required this.status, super.key});

  final DevelopmentStatus status;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(status.productName)),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              container: true,
              label:
                  '${status.productName}. ${status.headline}. ${status.detail}',
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.handshake_outlined,
                      color: Theme.of(context).colorScheme.primary,
                      size: 64,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      status.headline,
                      style: textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      status.detail,
                      style: textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
