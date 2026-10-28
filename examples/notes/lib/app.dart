import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'home_page.dart';
import 'note_store.dart';

class MarginApp extends StatelessWidget {
  const MarginApp({super.key, required this.store});

  final NoteStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'هامش',
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'IBMPlexSansArabic',
        scaffoldBackgroundColor: const Color(0xFF12100E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE15A3A),
          onPrimary: Color(0xFF1A120E),
          surface: Color(0xFF12100E),
          onSurface: Color(0xFFF6EFE4),
        ),
      ),
      home: HomePage(store: store),
    );
  }
}
