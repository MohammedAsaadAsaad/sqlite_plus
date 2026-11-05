import 'dart:io';

import 'package:flutter/material.dart';

import 'catalog_page.dart';
import 'catalog_work.dart';

class CatalogApp extends StatelessWidget {
  const CatalogApp({
    super.key,
    this.products,
    this.storeFile,
    this.prepareOnStart = true,
  });

  /// Replaces the bundled files in tests. The running app reads both assets.
  final ProductLoader? products;

  /// Replaces the documents-directory file in tests.
  final Future<File> Function()? storeFile;

  /// When true, a saved catalog is opened and a missing one is built once.
  final bool prepareOnStart;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF101418);
    const paper = Color(0xFFF3F0E8);
    const brass = Color(0xFFD7A15F);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Product catalog',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'IBMPlexSansArabic',
        scaffoldBackgroundColor: ink,
        cardTheme: const CardThemeData(color: Color(0xFF1A2128)),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF1A2128),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        colorScheme: const ColorScheme.dark(
          primary: brass,
          onPrimary: Color(0xFF1A140C),
          surface: ink,
          onSurface: paper,
          error: Color(0xFFFFB4AB),
        ),
      ),
      home: CatalogPage(
        products: products,
        storeFile: storeFile,
        prepareOnStart: prepareOnStart,
      ),
    );
  }
}
