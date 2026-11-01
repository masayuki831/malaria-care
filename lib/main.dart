import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'application/controller.dart';
import 'services/store.dart';
import 'services/notifications.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(defaultStore(), NotificationService());
  try {
    await controller.init();
    runApp(MalariaApp(controller: controller));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                '保存データを開けませんでした。データは上書きしていません。バックアップを確保し、管理者にご相談ください。',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MalariaApp extends StatelessWidget {
  final AppController controller;
  const MalariaApp({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Malaria Care',
    locale: const Locale('ja'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('ja'), Locale('en')],
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSansJP',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff186653),
        surface: const Color(0xfff7f9f7),
      ),
      scaffoldBackgroundColor: const Color(0xfff3f6f3),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff3f6f3),
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontWeight: FontWeight.w700,
          letterSpacing: -.6,
        ),
        titleLarge: TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    home: AppShell(controller: controller),
  );
}
