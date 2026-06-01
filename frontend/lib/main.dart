import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

void main() {
  runApp(const SelfMusicApp());
}

class SelfMusicApp extends StatelessWidget {
  const SelfMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SelfMusic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = 'Checking server...';

  @override
  void initState() {
    super.initState();
    _checkServer();
  }

  Future<void> _checkServer() async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: const String.fromEnvironment('API_BASE_URL',
            defaultValue: 'http://localhost:8080'),
        connectTimeout: const Duration(seconds: 5),
      ));
      final response = await dio.get('/api/health');
      setState(() => _status = 'Server: ${response.data['status']}');
    } catch (e) {
      setState(() => _status = 'Server unavailable: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SelfMusic')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            Icon(Icons.music_note, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Welcome to SelfMusic',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
      ),
    );
  }
}
