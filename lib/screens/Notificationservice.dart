import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  NotificationService
//
//  Singleton that handles ALL push notifications for the app:
//
//  ┌─ Sensor alerts ──────────────────────────────────────────────────────────┐
//  │  checkAndNotify()       fires when a sensor goes out of normal range.    │
//  └──────────────────────────────────────────────────────────────────────────┘
//  ┌─ Calibration ────────────────────────────────────────────────────────────┐
//  │  sendCalibrationAssigned()   fired when admin assigns a task to a user.  │
//  │  checkAdminMonthlyReminder() fired once/month for admin.                 │
//  └──────────────────────────────────────────────────────────────────────────┘
//  ┌─ Gate ───────────────────────────────────────────────────────────────────┐
//  │  setEnabled(bool)  — synced from Firebase users/{uid}/notifications/app  │
//  │  All send methods are no-ops when enabled == false.                      │
//  └──────────────────────────────────────────────────────────────────────────┘
// ─────────────────────────────────────────────────────────────────────────────

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // ── Gate — set from Firebase users/{uid}/notifications/app ───────────────
  bool _enabled = true; // default true until Firebase says otherwise

  /// Called by DashboardScreen whenever users/{uid}/notifications/app changes.
  void setEnabled(bool value) {
    _enabled = value;
    debugPrint('NotificationService: notifications ${value ? "ON" : "OFF"}');
  }

  bool get isEnabled => _enabled;

  // ── Dedup map: sensor key → was already out of range ─────────────────────
  final Map<String, bool> _wasOutOfRange = {};

  bool _initialised = false;

  // ── Channel ids ───────────────────────────────────────────────────────────
  static const _chSensor = 'sensor_alerts';
  static const _chSensorName = 'Alertes capteurs';
  static const _chSensorDesc = 'Notifications quand un capteur est hors norme';

  static const _chCalib = 'calibration_tasks';
  static const _chCalibName = 'Tâches de calibrage';
  static const _chCalibDesc = 'Notifications pour les tâches de calibrage';

  // ── Notification ids ──────────────────────────────────────────────────────
  static const Map<String, int> _sensorId = {
    'temperature': 1,
    'turbidite': 2,
    'ph': 3,
    'ec': 4,
  };
  static const int _calibAssignedId = 20;
  static const int _adminReminderBaseId = 30;

  // ── SharedPreferences key for admin reminder dedup ────────────────────────
  static const _kAdminReminderMonth = 'admin_reminder_last_month';

  // ── Sensor labels ─────────────────────────────────────────────────────────
  static const Map<String, String> _label = {
    'temperature': 'Température',
    'turbidite': 'Turbidité',
    'ph': 'pH',
    'ec': 'Conductivité',
  };

  static const List<String> _months = [
    '',
    'Janvier',
    'Février',
    'Mars',
    'Avril',
    'Mai',
    'Juin',
    'Juillet',
    'Août',
    'Septembre',
    'Octobre',
    'Novembre',
    'Décembre',
  ];

  // ─────────────────────────────────────────────────────────────────────────
  //  init — call once from main() or DashboardScreen.initState()
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialised) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
          android: android, iOS: darwin, macOS: darwin),
      onDidReceiveNotificationResponse: (d) =>
          debugPrint('Notification tapped: ${d.payload}'),
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _initialised = true;
    debugPrint('NotificationService: initialised');
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Sensor out-of-range check
  //  Call every time a new sensor value arrives from Firebase.
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> checkAndNotify({
    required String sensorKey,
    required double value,
    required double min,
    required double max,
    required String unit,
  }) async {
    if (!_enabled) return; // ← gate
    if (!_initialised) await init();

    final outNow = value < min || value > max;
    final wasOut = _wasOutOfRange[sensorKey] ?? false;

    if (outNow && !wasOut) {
      _wasOutOfRange[sensorKey] = true;
      await _show(
        id: _sensorId[sensorKey] ?? 99,
        title: '⚠️ ${_label[sensorKey] ?? sensorKey} hors norme !',
        body: 'Valeur : ${value.toStringAsFixed(2)} $unit   '
            '(norme : $min – $max $unit)',
        details: _sensorDetails(isAlert: true),
        payload: sensorKey,
      );
    } else if (!outNow && wasOut) {
      _wasOutOfRange[sensorKey] = false;
      await _show(
        id: (_sensorId[sensorKey] ?? 99) + 10,
        title: '✅ ${_label[sensorKey] ?? sensorKey} revenu à la normale',
        body: 'Valeur : ${value.toStringAsFixed(2)} $unit',
        details: _sensorDetails(isAlert: false),
        payload: sensorKey,
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Calibration assigned  (sent to the user)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> sendCalibrationAssigned({required String month}) async {
    if (!_enabled) return; // ← gate
    if (!_initialised) await init();

    await _show(
      id: _calibAssignedId,
      title: '🔧 Nouvelle tâche de calibrage',
      body: 'Un calibrage vous a été assigné pour $month.\n'
          'Ouvrez l\'app pour voir les détails.',
      details: _calibDetails(const Color(0xFF1565C0)),
      payload: 'calibration_assigned',
    );
    debugPrint('🔧 Calibration assigned — $month');
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Admin monthly reminder
  //  — Reminder #1 : first time admin opens the app in a new month  (purple)
  //  — Reminder #2 : after day 7 if some users still unassigned      (orange)
  //  Admin notifications are NOT gated by _enabled (they are for the admin).
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> checkAdminMonthlyReminder({
    required int assignedCount,
    required int totalCount,
  }) async {
    if (!_initialised) await init();

    final now = DateTime.now();
    final key = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final monthLabel = '${_months[now.month]} ${now.year}';
    final prefs = await SharedPreferences.getInstance();

    // ── Reminder #1 — once per month ─────────────────────────────────────
    if (prefs.getString(_kAdminReminderMonth) != key) {
      await prefs.setString(_kAdminReminderMonth, key);
      await _show(
        id: _adminReminderBaseId,
        title: '📋 Rappel calibrage — $monthLabel',
        body: totalCount == 0
            ? 'Aucun utilisateur enregistré pour le moment.'
            : 'Pensez à assigner les tâches de calibrage aux '
                '$totalCount utilisateurs pour $monthLabel.',
        details: _calibDetails(const Color(0xFF6A1B9A)),
        payload: 'admin_monthly_reminder',
      );
      debugPrint('📋 Admin monthly reminder — $monthLabel');
      return;
    }

    // ── Reminder #2 — follow-up after day 7 ──────────────────────────────
    if (now.day > 7 && assignedCount < totalCount) {
      final followKey = '${key}_followup';
      if (!(prefs.getBool(followKey) ?? false)) {
        await prefs.setBool(followKey, true);
        final rem = totalCount - assignedCount;
        await _show(
          id: _adminReminderBaseId + 1,
          title: '⏰ Calibrage incomplet — $monthLabel',
          body: '$rem utilisateur${rem > 1 ? 's' : ''} '
              'n\'${rem > 1 ? 'ont' : 'a'} pas encore été assigné'
              '${rem > 1 ? 's' : ''} ce mois-ci.',
          details: _calibDetails(const Color(0xFFE65100)),
          payload: 'admin_followup_reminder',
        );
        debugPrint('⏰ Admin follow-up — $rem unassigned');
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Internals
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
    String? payload,
  }) async {
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  NotificationDetails _sensorDetails({required bool isAlert}) {
    final color = isAlert ? const Color(0xFFE53935) : const Color(0xFF43A047);
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _chSensor,
        _chSensorName,
        channelDescription: _chSensorDesc,
        importance: isAlert ? Importance.high : Importance.defaultImportance,
        priority: isAlert ? Priority.high : Priority.defaultPriority,
        color: color,
        enableLights: true,
        ledColor: color,
        ledOnMs: 1000,
        ledOffMs: 500,
        ticker: isAlert ? 'Capteur hors norme' : 'Capteur normal',
        styleInformation: const BigTextStyleInformation(''),
      ),
      iOS: const DarwinNotificationDetails(
          presentAlert: true, presentBadge: true, presentSound: true),
      macOS: const DarwinNotificationDetails(
          presentAlert: true, presentBadge: true, presentSound: true),
    );
  }

  NotificationDetails _calibDetails(Color color) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _chCalib,
        _chCalibName,
        channelDescription: _chCalibDesc,
        importance: Importance.high,
        priority: Priority.high,
        color: color,
        enableLights: true,
        ledColor: color,
        ledOnMs: 1000,
        ledOffMs: 500,
        ticker: 'Calibrage',
        styleInformation: const BigTextStyleInformation(''),
      ),
      iOS: const DarwinNotificationDetails(
          presentAlert: true, presentBadge: true, presentSound: true),
      macOS: const DarwinNotificationDetails(
          presentAlert: true, presentBadge: true, presentSound: true),
    );
  }

  Future<void> cancelSensor(String key) async {
    final id = _sensorId[key];
    if (id != null) await _plugin.cancel(id: id);
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}
