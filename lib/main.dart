import 'package:flutter/material.dart';
import 'state/batch_controller.dart';
import 'views/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFFF8FAFC),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 56, color: Color(0xFFD97706)),
              const SizedBox(height: 16),
              const Text(
                'Notice: Display recovery active',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString(),
                style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  };
  runApp(const OcrToExcelApp());
}

/// Root widget configuring the Material 3 application theme and lifecycle.
class OcrToExcelApp extends StatefulWidget {
  const OcrToExcelApp({super.key});

  @override
  State<OcrToExcelApp> createState() => _OcrToExcelAppState();
}

class _OcrToExcelAppState extends State<OcrToExcelApp> {
  late final BatchProcessingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = BatchProcessingController(useGeminiBackend: true);
    _controller.checkLostData();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR to Excel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0), // Deep Royal Blue
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF0F172A),
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      themeMode: ThemeMode.light,
      home: LoginScreen(controller: _controller),
    );
  }
}
