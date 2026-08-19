import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService instance = PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  Future<void> init() async {
    debugPrint('🔥 PushNotificationService INIT CALLED');

    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      debugPrint('🔔 FCM permission: ${settings.authorizationStatus}');

      final token = await _messaging.getToken();

      debugPrint('📱 FCM TOKEN = $token');

      if (token != null) {
        await saveToken(token);
      } else {
        debugPrint('❌ FCM token is NULL');
      }

      _messaging.onTokenRefresh.listen((newToken) async {
        debugPrint('🔄 NEW FCM TOKEN = $newToken');
        await saveToken(newToken);
      });

      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('📩 FCM message received in foreground');
        debugPrint('Title: ${message.notification?.title}');
        debugPrint('Body: ${message.notification?.body}');
        debugPrint('Data: ${message.data}');
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('📲 Notification opened');
        debugPrint('Data: ${message.data}');
      });
    } catch (e) {
      debugPrint('❌ PushNotificationService error: $e');
    }
  }

  Future<void> saveToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;

    debugPrint('👤 CURRENT USER = ${user?.uid}');
    debugPrint('📱 TOKEN TO SAVE = $token');

    if (user == null) {
      debugPrint('❌ User not connected. Token not saved.');
      return;
    }

    try {
      await FirebaseDatabase.instance
          .ref('users/${user.uid}/fcmToken')
          .set(token);

      await FirebaseDatabase.instance
          .ref('users/${user.uid}/notifications/app')
          .set(true);

      await FirebaseDatabase.instance
          .ref('users/${user.uid}/notifications/sensorAlerts')
          .set(true);

      await FirebaseDatabase.instance
          .ref('users/${user.uid}/notifications/calibration')
          .set(true);

      debugPrint('✅ FCM token saved in Firebase for ${user.uid}');
    } catch (e) {
      debugPrint('❌ Error saving FCM token: $e');
    }
  }
}
