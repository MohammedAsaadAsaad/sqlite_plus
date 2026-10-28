import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'bench_model.dart';
import 'bench_page.dart';

class BenchApp extends StatelessWidget {
  const BenchApp({
    super.key,
    this.directory,
    this.engines,
    this.isolateSqlitePlus = true,
  });

  final Directory? directory;
  final List<BenchEngine>? engines;
  final bool isolateSqlitePlus;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Bench',
      locale: const Locale('en'),
      supportedLocales: const [Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'IBMPlexSansArabic',
        scaffoldBackgroundColor: const Color(0xFF101418),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE0A45A),
          onPrimary: Color(0xFF1A140C),
          surface: Color(0xFF101418),
          onSurface: Color(0xFFF4F1EA),
        ),
      ),
      home: BenchPage(
        directory: directory,
        engines: engines,
        isolateSqlitePlus: isolateSqlitePlus,
      ),
    );
  }
}
