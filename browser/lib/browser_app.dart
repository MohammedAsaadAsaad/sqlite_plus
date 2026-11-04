import 'package:flutter/material.dart';

import 'src/browser_page.dart';
import 'src/course_progress.dart';
import 'src/launch_bridge.dart';
import 'src/recent_files.dart';
import 'src/session.dart';

/// Desktop and mobile shell for one [BrowserSession].
class BrowserApp extends StatelessWidget {
  BrowserApp({
    super.key,
    required this.session,
    RecentStore? recents,
    CourseProgress? course,
    this.launch,
    this.launchMessage,
  })  : recents = recents ?? RecentStore.memory(),
        course = course ?? CourseProgress.memory();

  final BrowserSession session;
  final RecentStore recents;
  final CourseProgress course;

  /// A database passed on the command line or by the phone open action.
  final OpenedFile? launch;

  /// Why [launch] could not be read.
  final String? launchMessage;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF14211C);
    const line = Color(0xFFD9E2DC);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7C66),
      surface: const Color(0xFFF4F7F5),
    );
    return MaterialApp(
      title: 'SQLite Browser',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFEEF3F0),
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
        drawerTheme: const DrawerThemeData(
          backgroundColor: Colors.white,
        ),
        dividerColor: line,
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0E7C66),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: ink,
            side: const BorderSide(color: Color(0xFF0E7C66)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFD6EBE4),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final selected = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color:
                  selected ? const Color(0xFF0E7C66) : const Color(0xFF5C6560),
            );
          }),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(22)),
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
      home: BrowserPage(
        session: session,
        recents: recents,
        course: course,
        launch: launch,
        launchMessage: launchMessage,
      ),
    );
  }
}
