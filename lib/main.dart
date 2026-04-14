import 'package:flutter/material.dart';

import 'history.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReposterApp());
}

class ReposterApp extends StatefulWidget {
  const ReposterApp({super.key});

  static _ReposterAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_ReposterAppState>()!;

  @override
  State<ReposterApp> createState() => _ReposterAppState();
}

class _ReposterAppState extends State<ReposterApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  ThemeMode get themeMode => _themeMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Reposter',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFBF8FF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF151118),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
          surface: const Color(0xFF201B24),
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      home: const ReposterHomePage(),
    );
  }
}

class ReposterHomePage extends StatefulWidget {
  const ReposterHomePage({super.key});

  @override
  State<ReposterHomePage> createState() => _ReposterHomePageState();
}

class _ReposterHomePageState extends State<ReposterHomePage> {
  final GlobalKey<HistoryPageState> _historyKey = GlobalKey<HistoryPageState>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: theme.brightness == Brightness.dark
                  ? const Color(0xFF1F1A24)
                  : const Color(0xFFF0F0F5),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/reposter.png',
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('Reposter', style: theme.textTheme.headlineMedium),
                    const Spacer(),
                    IconButton(
                      onPressed: () => _historyKey.currentState?.deleteAll(),
                      icon: Icon(
                        Icons.delete_outline,
                        color: theme.brightness == Brightness.dark
                            ? Colors.white54
                            : Colors.black54,
                      ),
                      tooltip: 'Delete all',
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => ReposterApp.of(context).toggleTheme(),
                      child: Container(
                        width: 64,
                        height: 34,
                        decoration: BoxDecoration(
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF332C3B)
                              : Colors.grey[300],
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Stack(
                          children: [
                            AnimatedAlign(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOutCubic,
                              alignment: theme.brightness == Brightness.light
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.all(2.0),
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  alignment: Alignment.center,
                                  child: Icon(
                                    theme.brightness == Brightness.light
                                        ? Icons.light_mode_rounded
                                        : Icons.dark_mode_rounded,
                                    size: 20,
                                    color: theme.brightness == Brightness.light
                                        ? Colors.orange
                                        : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: HistoryPage(key: _historyKey)),
          ],
        ),
      ),
    );
  }
}
