import 'package:flutter/material.dart';

import 'src/browser_page.dart';
import 'src/session.dart';

/// Desktop and mobile shell for one [BrowserSession].
class BrowserApp extends StatelessWidget {
  const BrowserApp({super.key, required this.session});

  final BrowserSession session;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF14211C);
    const line = Color(0xFFD9E2DC);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7C66),
      surface: const Color(0xFFF4F7F5),
    );
    return MaterialApp(
      title: 'sqlite_plus browser',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF4F7F5),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: ink,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        dividerColor: line,
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0E7C66),
            foregroundColor: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: line),
          ),
        ),
      ),
      home: BrowserPage(session: session),
    );
  }
}
