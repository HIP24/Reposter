import 'package:flutter/material.dart';

import 'repost_service.dart';
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
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/reposter.png',
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Reposter',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.8,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                      onPressed: () => _historyKey.currentState?.deleteAll(),
                      icon: Icon(
                        Icons.delete_outline,
                        size: 24,
                        color: theme.brightness == Brightness.dark
                            ? Colors.white.withOpacity(0.9)
                            : Colors.black.withOpacity(0.7),
                      ),
                      tooltip: 'Delete all',
                    ),
                    const SizedBox(width: 4),
                    // Platform Filter Toggle
                    Container(
                      height: 36,
                      width: 88, 
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? Colors.black.withOpacity(0.2)
                            : Colors.black.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white10
                              : Colors.black.withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Material(
                          color: Colors.transparent,
                          child: Row(
                            children: [
                              // Instagram half
                              Expanded(
                                child: InkWell(
                                  onTap: () => setState(() => _historyKey.currentState?.togglePlatform(SocialPlatform.instagram)),
                                  child: Container(
                                    alignment: Alignment.center,
                                    color: Colors.transparent,
                                    child: Image.asset(
                                      theme.brightness == Brightness.dark
                                          ? 'assets/social_media/instagram-dark.png'
                                          : 'assets/social_media/instagram-light.png',
                                      width: (_historyKey.currentState?.isPlatformActive(SocialPlatform.instagram) ?? true) ? 17 : 14,
                                      height: (_historyKey.currentState?.isPlatformActive(SocialPlatform.instagram) ?? true) ? 17 : 14,
                                      color: (_historyKey.currentState?.isPlatformActive(SocialPlatform.instagram) ?? true)
                                          ? null
                                          : Colors.grey.withOpacity(0.5),
                                    ),
                                  ),
                                ),
                              ),
                              // Vertical divider
                              Container(
                                width: 1,
                                height: 16,
                                color: theme.brightness == Brightness.dark
                                    ? Colors.white.withOpacity(0.05)
                                    : Colors.black.withOpacity(0.05),
                              ),
                              // TikTok half
                              Expanded(
                                child: InkWell(
                                  onTap: () => setState(() => _historyKey.currentState?.togglePlatform(SocialPlatform.tiktok)),
                                  child: Container(
                                    alignment: Alignment.center,
                                    color: Colors.transparent,
                                    child: Image.asset(
                                      theme.brightness == Brightness.dark
                                          ? 'assets/social_media/tiktok-dark.png'
                                          : 'assets/social_media/tiktok-light.png',
                                      width: (_historyKey.currentState?.isPlatformActive(SocialPlatform.tiktok) ?? true) ? 20 : 17,
                                      height: (_historyKey.currentState?.isPlatformActive(SocialPlatform.tiktok) ?? true) ? 20 : 17,
                                      color: (_historyKey.currentState?.isPlatformActive(SocialPlatform.tiktok) ?? true)
                                          ? null
                                          : Colors.grey.withOpacity(0.5),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => ReposterApp.of(context).toggleTheme(),
                      child: Container(
                        width: 62,
                        height: 36,
                        decoration: BoxDecoration(
                          color: theme.brightness == Brightness.dark
                              ? Colors.black.withOpacity(0.2)
                              : Colors.black.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: theme.brightness == Brightness.dark
                                ? Colors.white10
                                : Colors.black.withOpacity(0.1),
                            width: 1,
                          ),
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
                                padding: const EdgeInsets.all(3.0),
                                child: Container(
                                  width: 30,
                                  height: 30,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: theme.brightness == Brightness.dark
                                        ? const Color(0xFF332C3B)
                                        : Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: theme.brightness == Brightness.light
                                        ? [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.1),
                                              blurRadius: 4,
                                              offset: const Offset(0, 2),
                                            )
                                          ]
                                        : null,
                                  ),
                                  child: Icon(
                                    theme.brightness == Brightness.light
                                        ? Icons.light_mode_rounded
                                        : Icons.dark_mode_rounded,
                                    size: 18,
                                    color: theme.brightness == Brightness.light
                                        ? Colors.black.withOpacity(0.7)
                                        : Colors.white.withOpacity(0.9),
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
