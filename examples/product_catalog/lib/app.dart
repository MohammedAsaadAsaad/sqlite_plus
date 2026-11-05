import 'package:flutter/material.dart';

import 'catalog_page.dart';
import 'catalog_work.dart';

class CatalogApp extends StatelessWidget {
  const CatalogApp({super.key, this.products});

  /// Replaces the bundled files in tests. The running app reads both assets.
  final ProductLoader? products;

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
        colorScheme: const ColorScheme.dark(
          primary: brass,
          onPrimary: Color(0xFF1A140C),
          surface: ink,
          onSurface: paper,
          error: Color(0xFFFFB4AB),
        ),
      ),
      home: CatalogPage(products: products),
    );
  }
}
