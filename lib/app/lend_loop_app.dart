import 'package:flutter/material.dart';
import 'package:lend_loop/app/development_status.dart';
import 'package:lend_loop/features/development/development_screen.dart';

class LendLoopApp extends StatelessWidget {
  const LendLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: DevelopmentStatus.current.productName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF315C49)),
        useMaterial3: true,
      ),
      home: const DevelopmentScreen(status: DevelopmentStatus.current),
    );
  }
}
