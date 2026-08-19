import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:water_app/firebase_options.dart';
import 'theme.dart';
import 'screens/logo.dart';
import 'translations.dart';
import 'screens/Notificationservice.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/push_notification.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📩 Background FCM message: ${message.messageId}');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  await PushNotificationService.instance.init();
  await NotificationService.instance.init();
  runApp(const WaterApp()); // Launch the app
}

class WaterApp extends StatefulWidget {
  const WaterApp({super.key});

  @override
  State<WaterApp> createState() => _WaterAppState();
}

class _WaterAppState extends State<WaterApp> {
  late Locale _locale;
  final Translations _translations = Translations();

  @override
  void initState() {
    super.initState();
    _locale = const Locale('en');
    _translations.setLocale(_locale);
  }

  void _changeLanguage(Locale newLocale) {
    setState(() {
      _locale = newLocale;
      _translations.setLocale(newLocale);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      locale: _locale,
      supportedLocales: const [
        Locale('en'),
        Locale('fr'),
        Locale('ar'),
        Locale('de'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Logo(
        currentLocale: _locale,
        onLocaleChanged: _changeLanguage,
      ),
    );
  }

  void setupAuthGuard(BuildContext context) {
    FirebaseAuth.instance.authStateChanges().listen((user) async {
      if (user != null) {
        final snap =
            await FirebaseDatabase.instance.ref('users/${user.uid}').get();

        if (!snap.exists) {
          // User deleted from DB but still in Auth -> force sign out.
          await FirebaseAuth.instance.signOut();

          // Navigate to your login screen.
          if (context.mounted) {
            Navigator.of(context).pushNamedAndRemoveUntil(
              '/login', // replace with your login route
              (route) => false,
            );
          }
        }
      }
    });
  }
}
