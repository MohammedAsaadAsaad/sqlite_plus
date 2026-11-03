import 'package:flutter/material.dart';

import 'src/browser_page.dart';
import 'src/session.dart';

/// Desktop and mobile shell for one [BrowserSession].
class BrowserApp extends StatelessWidget {
  const BrowserApp({super.key, required this.session});

  final BrowserSession session;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1F6B4A),
      surface: const Color(0xFFF3F0E8),
    );
    return MaterialApp(
      title: 'sqlite_plus browser',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF3F0E8),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF3F0E8),
          foregroundColor: Color(0xFF1B2421),
          elevation: 0,
        ),
        dividerColor: const Color(0xFFD9D3C7),
      ),
      home: BrowserPage(session: session),
    );
  }
}
