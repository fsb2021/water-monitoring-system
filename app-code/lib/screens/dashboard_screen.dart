import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'app_background.dart';
import 'ChartsScreen.dart';
import 'SettingsScreen.dart';
import 'graphic.dart';
import 'calibration_screen.dart';
import 'checklist.dart';
import '../translations.dart';
import 'notificationservice.dart'; // ← import the service

// ─────────────────────────────────────────────────────────────────────────────
//  Sensor normal ranges  (edit here to adjust thresholds)
// ─────────────────────────────────────────────────────────────────────────────

class SensorRange {
  final double min;
  final double max;
  final String unit;
  const SensorRange({required this.min, required this.max, required this.unit});
}

const Map<String, SensorRange> kSensorRanges = {
  'temperature': SensorRange(min: 10, max: 18, unit: '°C'),
  'turbidite': SensorRange(min: 0, max: 100, unit: 'NTU'),
  'ph': SensorRange(min: 7.5, max: 9, unit: ''),
  'ec': SensorRange(min: 0, max: 100.0, unit: 'µs/cm'),
};

// ─────────────────────────────────────────────────────────────────────────────
//  DashboardScreen
// ─────────────────────────────────────────────────────────────────────────────

class DashboardScreen extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const DashboardScreen({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // ── Services ──────────────────────────────────────────────────────────────
  final Translations _translations = Translations();

  // Firebase refs — one per sensor node
  final DatabaseReference _ecRef =
      FirebaseDatabase.instance.ref().child('capteurs/ec');
  final DatabaseReference _phRef =
      FirebaseDatabase.instance.ref().child('capteurs/ph');
  final DatabaseReference _tempRef =
      FirebaseDatabase.instance.ref().child('capteurs/temp');
  final DatabaseReference _turbRef =
      FirebaseDatabase.instance.ref().child('capteurs/turbidite');

  // ── Stream subscriptions ──────────────────────────────────────────────────
  late StreamSubscription<DatabaseEvent> _ecSubscription;
  late StreamSubscription<DatabaseEvent> _phSubscription;
  late StreamSubscription<DatabaseEvent> _tempSubscription;
  late StreamSubscription<DatabaseEvent> _turbSubscription;
  StreamSubscription<DatabaseEvent>? _calibSubscription;
  StreamSubscription<DatabaseEvent>? _notifSubscription;

  // ── Sensor values ─────────────────────────────────────────────────────────
  double temperature = 0;
  double turbidite = 0;
  double ph = 0;
  double ec = 0;

  String _tempTimestamp = '--/--/---- --:--';
  String _turbTimestamp = '--/--/---- --:--';
  String _phTimestamp = '--/--/---- --:--';
  String _ecTimestamp = '--/--/---- --:--';

  // ── User info ─────────────────────────────────────────────────────────────
  String _userName = '';
  String _userRole = AppRole.user;
  bool _userLoaded = false;

  // ── Calibration status ────────────────────────────────────────────────────
  bool _calibAssigned = false;
  bool _calibPhDone = false;
  bool _calibCondDone = false;
  // Track previous state to fire notification only on false → true transition

  // ── Bottom-nav state ──────────────────────────────────────────────────────
  int _selectedIndex = 0;

  // ─────────────────────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────────────────────

  String _tr(String key) {
    _translations.setLocale(Localizations.localeOf(context));
    return _translations.translate(key);
  }

  String get _currentMonth {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  bool get _isAdmin => AppRole.isAdmin(_userRole);

  Color get _roleColor =>
      _isAdmin ? Colors.red.shade600 : Colors.blueGrey.shade600;

  bool _isOutOfRange(String key, double value) {
    final range = kSensorRanges[key];
    if (range == null) return false;
    return value < range.min || value > range.max;
  }

  bool _isEcWarning(double value) => value > 100 && value < 500;

  bool _isEcCritical(double value) => value > 500;

  // ─────────────────────────────────────────────────────────────────────────
  //  Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Initialise notification service as early as possible
    NotificationService.instance.init();
    _startEcStream();
    _startPhStream();
    _startTempStream();
    _startTurbStream();
    _loadUserInfo();
  }

  @override
  void dispose() {
    _ecSubscription.cancel();
    _phSubscription.cancel();
    _tempSubscription.cancel();
    _turbSubscription.cancel();
    _calibSubscription?.cancel();
    _notifSubscription?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Sensor streams
  //  Each node: { date, time, value }
  // ─────────────────────────────────────────────────────────────────────────

  void _startEcStream() {
    _ecSubscription = _ecRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      final value = _parseDouble(snap.child('value').value);
      setState(() {
        ec = value;
        _ecTimestamp = _resolveTimestamp(snap);
      });
      // ── Notification check ──────────────────────────────────────────────
      // Use the generic checkAndNotify method (exists on NotificationService).
      // For EC we consider normal range 0–100 µS/cm; values above that
      // are treated as out-of-range (UI shows warning/critical thresholds).
      NotificationService.instance.checkAndNotify(
        sensorKey: 'ec',
        value: value,
        min: 0,
        max: 100,
        unit: kSensorRanges['ec']!.unit,
      );
    }, onError: (e) => debugPrint('EC stream error: $e'));
  }

  void _startPhStream() {
    _phSubscription = _phRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      final value = _parseDouble(snap.child('value').value);
      setState(() {
        ph = value;
        _phTimestamp = _resolveTimestamp(snap);
      });
      // ── Notification check ──────────────────────────────────────────────
      final r = kSensorRanges['ph']!;
      NotificationService.instance.checkAndNotify(
        sensorKey: 'ph',
        value: value,
        min: r.min,
        max: r.max,
        unit: r.unit,
      );
    }, onError: (e) => debugPrint('pH stream error: $e'));
  }

  void _startTempStream() {
    _tempSubscription = _tempRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      final value = _parseDouble(snap.child('value').value);
      setState(() {
        temperature = value;
        _tempTimestamp = _resolveTimestamp(snap);
      });
      // ── Notification check ──────────────────────────────────────────────
      final r = kSensorRanges['temperature']!;
      NotificationService.instance.checkAndNotify(
        sensorKey: 'temperature',
        value: value,
        min: r.min,
        max: r.max,
        unit: r.unit,
      );
    }, onError: (e) => debugPrint('Temp stream error: $e'));
  }

  void _startTurbStream() {
    _turbSubscription = _turbRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      final value = _parseDouble(snap.child('value').value);
      setState(() {
        turbidite = value;
        _turbTimestamp = _resolveTimestamp(snap);
      });
      // ── Notification check ──────────────────────────────────────────────
      final r = kSensorRanges['turbidite']!;
      NotificationService.instance.checkAndNotify(
        sensorKey: 'turbidite',
        value: value,
        min: r.min,
        max: r.max,
        unit: r.unit,
      );
    }, onError: (e) => debugPrint('Turbidity stream error: $e'));
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Timestamp resolver
  //  Priority: date+time fields → timestamp string → legacy epoch
  // ─────────────────────────────────────────────────────────────────────────

  String _resolveTimestamp(DataSnapshot snap) {
    // 1️⃣  date + time fields (e.g. "13/05/2026" + "13:26")
    final date = snap.child('date').value?.toString().trim() ?? '';
    final time = snap.child('time').value?.toString().trim() ?? '';
    if (date.isNotEmpty && time.isNotEmpty) return '$date $time';

    // 2️⃣  timestamp string fallback (e.g. "18/04/2026 17:16")
    final ts = snap.child('timestamp').value?.toString().trim() ?? '';
    if (ts.isNotEmpty && ts != 'null') return _shortenTimestamp(ts);

    // 3️⃣  legacy epoch fallback
    return _parseEpochTimestamp(snap.child('timestamp').value);
  }

  /// Trims seconds from "dd/MM/yyyy HH:mm:ss" → "dd/MM/yyyy HH:mm"
  String _shortenTimestamp(String ts) {
    if (!ts.contains('/')) return ts;
    final parts = ts.split(' ');
    if (parts.length < 2) return ts;
    final timeParts = parts[1].split(':');
    final timeShort =
        timeParts.length >= 2 ? '${timeParts[0]}:${timeParts[1]}' : parts[1];
    return '${parts[0]} $timeShort';
  }

  String _parseEpochTimestamp(dynamic raw) {
    if (raw == null) return '--/--/---- --:--';
    int? ms;
    if (raw is int) {
      ms = raw;
    } else if (raw is double) {
      ms = raw.toInt();
    } else {
      ms = int.tryParse(raw.toString());
    }
    if (ms == null || ms == 0) return '--/--/---- --:--';
    if (ms < 1_000_000_000) ms *= 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  double _parseDouble(dynamic value) =>
      double.tryParse(value?.toString() ?? '0') ?? 0;

  // ─────────────────────────────────────────────────────────────────────────
  //  User info + role
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadUserInfo() async {
    final User? currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      final snap =
          await FirebaseDatabase.instance.ref('users/${currentUser.uid}').get();

      String resolvedName;
      String resolvedRole;

      if (!snap.exists || snap.value is! Map) {
        resolvedName = currentUser.displayName?.trim().isNotEmpty == true
            ? currentUser.displayName!.trim()
            : currentUser.email?.split('@').first ?? 'User';
        resolvedRole = AppRole.user;
      } else {
        final data = snap.value as Map<dynamic, dynamic>;
        resolvedName = data['name']?.toString().trim().isNotEmpty == true
            ? data['name'].toString().trim()
            : currentUser.displayName?.trim().isNotEmpty == true
                ? currentUser.displayName!.trim()
                : currentUser.email?.split('@').first ?? 'User';
        final rawRole = data['role'] ?? data['userRole'] ?? data['type'];
        final normalised = rawRole?.toString().trim().toLowerCase() ?? '';
        resolvedRole = normalised.isEmpty ? AppRole.user : normalised;
      }

      if (!mounted) return;
      setState(() {
        _userName = resolvedName;
        _userRole = resolvedRole;
        _userLoaded = true;
      });

      // Listen for this user's notification setting so we can gate notifications
      // on the device whenever an admin (or the user) changes the setting.
      _notifSubscription?.cancel();
      _notifSubscription = FirebaseDatabase.instance
          .ref('users/${currentUser.uid}/notifications/app')
          .onValue
          .listen((evt) {
        final v = evt.snapshot.value;
        final enabled = v == true || v?.toString() == 'true';
        NotificationService.instance.setEnabled(enabled);
      }, onError: (e) => debugPrint('Notif setting listen error: $e'));

      if (!AppRole.isAdmin(resolvedRole)) {
        _listenToCalibration(currentUser.uid);
      }
    } catch (e) {
      debugPrint('Error loading user info: $e');
      if (!mounted) return;
      setState(() {
        _userName = currentUser.email?.split('@').first ?? 'User';
        _userRole = AppRole.user;
        _userLoaded = true;
      });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Calibration listener
  // ─────────────────────────────────────────────────────────────────────────

  void _listenToCalibration(String uid) {
    _calibSubscription?.cancel();
    _calibSubscription = FirebaseDatabase.instance
        .ref('calibrations/$uid/$_currentMonth')
        .onValue
        .listen((event) {
      final snap = event.snapshot;
      if (!mounted) return;
      if (!snap.exists || snap.value is! Map) {
        setState(() {
          _calibAssigned = false;
          _calibPhDone = false;
          _calibCondDone = false;
        });
        return;
      }
      final data = snap.value as Map<dynamic, dynamic>;
      final newAssigned = data['assignedBy']?.toString().isNotEmpty == true;
      final wasAssigned = _calibAssigned;

      // Fire notification only when transitioning from not-assigned → assigned
      if (newAssigned && !wasAssigned) {
        final now = DateTime.now();
        const months = [
          '',
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December',
        ];
        final monthLabel = '${months[now.month]} ${now.year}';
        NotificationService.instance.sendCalibrationAssigned(month: monthLabel);
      }

      setState(() {
        _calibAssigned = newAssigned;
        _calibPhDone = data['phDone'] == true;
        _calibCondDone = data['conductivityDone'] == true;
      });
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Navigation
  // ─────────────────────────────────────────────────────────────────────────

  void _onBottomNavTap(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    switch (index) {
      case 0:
        return;
      case 1:
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => Graphic(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
      case 2:
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ChartsScreen(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
      case 3:
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => SettingsScreen(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tr('dashboard')),
        centerTitle: true,
      ),
      drawer: _buildDrawer(),
      body: AppBackground(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_userLoaded) _buildWelcomeHeader(),
                  const SizedBox(height: 20),
                  if (_userLoaded && !_isAdmin)
                    _CalibrationCard(
                      isAssigned: _calibAssigned,
                      phDone: _calibPhDone,
                      condDone: _calibCondDone,
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => CalibrationScreen(
                                  currentLocale: widget.currentLocale,
                                  onLocaleChanged: widget.onLocaleChanged))),
                    ),
                  if (_userLoaded && _isAdmin)
                    _AdminCalibrationOverviewCard(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const AdminCalibrationScreen())),
                    ),
                  const SizedBox(height: 14),
                  Expanded(child: _buildSensorGrid()),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Sub-builders
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildWelcomeHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _roleColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _roleColor.withOpacity(0.25), width: 1.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Welcome back,',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.65),
                        fontSize: 12,
                        letterSpacing: 0.3)),
                const SizedBox(height: 4),
                Text(_userName,
                    style: TextStyle(
                        color: _roleColor,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _roleColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _isAdmin ? '👤 ADMIN' : '👤 USER',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _roleColor,
                  letterSpacing: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorGrid() {
    final lastUpdateLabel = _tr('last_update');
    final range = kSensorRanges;

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 18,
      mainAxisSpacing: 20,
      childAspectRatio: 0.75,
      children: [
        // ── Temperature ───────────────────────────────────────────────────
        SensorCard(
          title: _tr('temperature'),
          value: '${temperature.toStringAsFixed(1)} °C',
          icon: Icons.thermostat,
          normalColor: Colors.orange,
          isOutOfRange: _isOutOfRange('temperature', temperature),
          rangeMin: range['temperature']!.min,
          rangeMax: range['temperature']!.max,
          unit: range['temperature']!.unit,
          lastUpdate: _tempTimestamp,
          lastUpdateLabel: lastUpdateLabel,
        ),

        // ── Turbidity ─────────────────────────────────────────────────────
        SensorCard(
          title: _tr('turbidity'),
          value: '${turbidite.toStringAsFixed(2)} NTU',
          icon: Icons.water_drop,
          normalColor: const Color.fromARGB(255, 2, 90, 161),
          isOutOfRange: _isOutOfRange('turbidite', turbidite),
          rangeMin: range['turbidite']!.min,
          rangeMax: range['turbidite']!.max,
          unit: range['turbidite']!.unit,
          lastUpdate: _turbTimestamp,
          lastUpdateLabel: lastUpdateLabel,
        ),

        // ── pH ────────────────────────────────────────────────────────────
        SensorCard(
          title: 'pH',
          value: ph.toStringAsFixed(2),
          icon: Icons.science,
          normalColor: Colors.green,
          isOutOfRange: _isOutOfRange('ph', ph),
          rangeMin: range['ph']!.min,
          rangeMax: range['ph']!.max,
          unit: range['ph']!.unit,
          lastUpdate: _phTimestamp,
          lastUpdateLabel: lastUpdateLabel,
        ),

        // ── Electrical Conductivity ───────────────────────────────────────
        SensorCard(
          title: _tr('conductivity'),
          value: '${ec.toStringAsFixed(2)} µS/cm',
          icon: Icons.electrical_services,
          normalColor: const Color(0xFF9C27B0),
          isOutOfRange: _isEcCritical(ec),
          isWarning: _isEcWarning(ec),
          rangeMin: 0,
          rangeMax: 100,
          unit: range['ec']!.unit,
          lastUpdate: _ecTimestamp,
          lastUpdateLabel: lastUpdateLabel,
          rangeLabel: _isEcCritical(ec)
              ? '> 500 µS/cm'
              : _isEcWarning(ec)
                  ? '100 – 500 µS/cm'
                  : '< 100 µS/cm',
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: _roleColor),
            accountName: Row(
              children: [
                Text(_userLoaded ? _userName : '…',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                if (_userLoaded)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _isAdmin ? 'ADMIN' : _userRole.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ),
              ],
            ),
            accountEmail: Text(FirebaseAuth.instance.currentUser?.email ?? ''),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Colors.white,
              child: Text(
                _userName.isNotEmpty ? _userName[0].toUpperCase() : 'U',
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: _roleColor),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home),
            title: Text(_tr('dashboard')),
            onTap: () => Navigator.pop(context),
          ),
          if (_userLoaded && !_isAdmin)
            ListTile(
              leading: Icon(
                Icons.checklist_rtl,
                color: !_calibAssigned
                    ? Colors.grey
                    : (_calibPhDone && _calibCondDone
                        ? Colors.green
                        : Colors.orange),
              ),
              title: const Text('My Calibration'),
              subtitle: Text(
                !_calibAssigned
                    ? 'Not assigned yet'
                    : (_calibPhDone && _calibCondDone
                        ? 'All done this month ✓'
                        : 'In progress…'),
                style: const TextStyle(fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => CalibrationScreen(
                            currentLocale: widget.currentLocale,
                            onLocaleChanged: widget.onLocaleChanged)));
              },
            ),
          if (_userLoaded && _isAdmin) ...[
            const Divider(),
            const Padding(
              padding: EdgeInsets.only(left: 16, top: 8, bottom: 4),
              child: Text('ADMIN',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                      letterSpacing: 1.2)),
            ),
            ListTile(
              leading:
                  const Icon(Icons.assignment_turned_in, color: Colors.red),
              title: const Text('Calibration Tasks'),
              subtitle: const Text('Assign & track users',
                  style: TextStyle(fontSize: 12)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AdminCalibrationScreen()));
              },
            ),
          ],
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Logout', style: TextStyle(color: Colors.red)),
            onTap: () async {
              Navigator.pop(context);
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: Color.fromRGBO(184, 203, 208, 1),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(5),
          topRight: Radius.circular(5),
        ),
      ),
      child: BottomNavigationBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        currentIndex: _selectedIndex,
        onTap: _onBottomNavTap,
        selectedItemColor: Colors.white,
        unselectedItemColor: const Color.fromARGB(137, 131, 124, 124),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: ''),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: ''),
          BottomNavigationBarItem(
              icon: Icon(Icons.add_box_outlined), label: ''),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: ''),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SensorCard  (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class SensorCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color normalColor;
  final bool isWarning;
  final bool isOutOfRange;
  final double rangeMin;
  final double rangeMax;
  final String unit;
  final String? rangeLabel;
  final String lastUpdate;
  final String lastUpdateLabel;

  const SensorCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.normalColor,
    this.isWarning = false,
    required this.isOutOfRange,
    required this.rangeMin,
    required this.rangeMax,
    required this.unit,
    this.rangeLabel,
    required this.lastUpdate,
    required this.lastUpdateLabel,
  });

  @override
  Widget build(BuildContext context) {
    final Color accentColor = isOutOfRange
        ? Colors.red.shade400
        : isWarning
            ? Colors.orange.shade400
            : normalColor;
    final Color borderColor = isOutOfRange
        ? Colors.red.shade400.withOpacity(0.8)
        : isWarning
            ? Colors.orange.shade400.withOpacity(0.8)
            : normalColor.withOpacity(0.4);
    final Color bgColor = isOutOfRange
        ? Colors.red.shade900.withOpacity(0.25)
        : isWarning
            ? Colors.orange.shade900.withOpacity(0.20)
            : Colors.transparent;
    final Color iconBg = accentColor.withOpacity(0.15);

    final parts = lastUpdate.split(' ');
    final datePart = parts.isNotEmpty ? parts[0] : '--/--/----';
    final timePart = parts.length > 1 ? parts[1] : '--:--';

    final String resolvedRangeLabel = rangeLabel ??
        (unit.isEmpty
            ? '$rangeMin – $rangeMax'
            : '$rangeMin – $rangeMax $unit');

    return Card(
      color: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(18),
          border:
              Border.all(color: borderColor, width: isOutOfRange ? 2.0 : 1.8),
          boxShadow: [
            BoxShadow(
              color: (isOutOfRange ? Colors.red : normalColor)
                  .withOpacity(isOutOfRange ? 0.4 : 0.15),
              blurRadius: isOutOfRange ? 16 : 10,
              spreadRadius: isOutOfRange ? 2 : 1,
            )
          ],
        ),
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isOutOfRange || isWarning)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 5),
                  padding:
                      const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                  decoration: BoxDecoration(
                    color: isOutOfRange
                        ? Colors.red.shade700
                        : Colors.orange.shade700,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: (isOutOfRange ? Colors.red : Colors.orange)
                            .withOpacity(0.3),
                        blurRadius: 6,
                        spreadRadius: 1,
                      )
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        isOutOfRange ? 'OUT OF RANGE' : 'WARNING',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.4),
                      ),
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: iconBg,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 24, color: accentColor),
              ),
              SizedBox(height: isOutOfRange ? 5 : 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: isOutOfRange ? 13 : 15,
                    fontWeight: FontWeight.w600,
                    color: const Color.fromARGB(221, 255, 252, 252)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              SizedBox(height: isOutOfRange ? 4 : 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TextStyle(
                      fontSize: isOutOfRange ? 20 : 22,
                      color: accentColor,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: isOutOfRange
                      ? Colors.red.withOpacity(0.15)
                      : normalColor.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isOutOfRange
                        ? Colors.red.withOpacity(0.5)
                        : normalColor.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 9,
                      color: isOutOfRange ? Colors.red.shade300 : normalColor,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      resolvedRangeLabel,
                      style: TextStyle(
                        fontSize: 10,
                        color: isOutOfRange
                            ? Colors.red.shade300
                            : normalColor.withOpacity(0.9),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: isOutOfRange ? 3 : 6),
              Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today,
                          size: 9, color: Colors.grey),
                      const SizedBox(width: 2),
                      Text(datePart,
                          style:
                              const TextStyle(fontSize: 8, color: Colors.grey)),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.access_time,
                          size: 9, color: Colors.grey),
                      const SizedBox(width: 2),
                      Text('$lastUpdateLabel: $timePart',
                          style:
                              const TextStyle(fontSize: 8, color: Colors.grey)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _CalibrationCard  (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class _CalibrationCard extends StatelessWidget {
  final bool isAssigned;
  final bool phDone;
  final bool condDone;
  final VoidCallback onTap;

  const _CalibrationCard({
    required this.isAssigned,
    required this.phDone,
    required this.condDone,
    required this.onTap,
  });

  static const _months = [
    '',
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  Widget build(BuildContext context) {
    final allDone = phDone && condDone;
    final now = DateTime.now();

    final Color cardColor;
    final String statusText;
    final IconData statusIcon;

    if (!isAssigned) {
      cardColor = Colors.blueGrey;
      statusText = 'No task assigned this month';
      statusIcon = Icons.pending_actions;
    } else if (allDone) {
      cardColor = Colors.green;
      statusText = 'All sensors calibrated ✓';
      statusIcon = Icons.check_circle;
    } else {
      cardColor = Colors.orange;
      statusText = 'Calibration pending';
      statusIcon = Icons.timelapse;
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor.withOpacity(0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cardColor.withOpacity(0.4), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cardColor.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(statusIcon, color: cardColor, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Monthly Calibration — ${_months[now.month]}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                  const SizedBox(height: 3),
                  Text(statusText,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.8), fontSize: 12)),
                  if (isAssigned) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _MiniSensorBadge(
                            label: 'pH', done: phDone, color: cardColor),
                        const SizedBox(width: 6),
                        _MiniSensorBadge(
                            label: 'Cond.', done: condDone, color: cardColor),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios,
                color: Colors.white.withOpacity(0.5), size: 16),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _MiniSensorBadge  (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class _MiniSensorBadge extends StatelessWidget {
  final String label;
  final bool done;
  final Color color;

  const _MiniSensorBadge({
    required this.label,
    required this.done,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: done ? Colors.white.withOpacity(0.2) : Colors.white10,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: done ? Colors.white54 : Colors.white24),
      ),
      child: Text(
        '${done ? "✓" : "○"} $label',
        style: TextStyle(
            color: done ? Colors.white : Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  _AdminCalibrationOverviewCard  (unchanged)
// ─────────────────────────────────────────────────────────────────────────────

class _AdminCalibrationOverviewCard extends StatefulWidget {
  final VoidCallback onTap;
  const _AdminCalibrationOverviewCard({required this.onTap});

  @override
  State<_AdminCalibrationOverviewCard> createState() =>
      _AdminCalibrationOverviewCardState();
}

class _AdminCalibrationOverviewCardState
    extends State<_AdminCalibrationOverviewCard> {
  int _total = 0;
  int _assigned = 0;
  int _completed = 0;
  bool _loaded = false;

  String get _currentMonth {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final usersSnap = await FirebaseDatabase.instance.ref('users').get();
      if (!usersSnap.exists || usersSnap.value is! Map) return;

      final usersData = usersSnap.value as Map<dynamic, dynamic>;
      int total = 0, assigned = 0, completed = 0;

      for (final entry in usersData.entries) {
        final uid = entry.key.toString();
        final uData = entry.value;
        if (uData is! Map) continue;

        final rawRole = uData['role'] ?? uData['userRole'] ?? uData['type'];
        final role = rawRole?.toString().toLowerCase() ?? AppRole.user;
        if (AppRole.isAdmin(role)) continue;
        total++;

        final calibSnap = await FirebaseDatabase.instance
            .ref('calibrations/$uid/$_currentMonth')
            .get();

        if (calibSnap.exists && calibSnap.value is Map) {
          final cData = calibSnap.value as Map<dynamic, dynamic>;
          final isAssigned = cData['assignedBy']?.toString().isNotEmpty == true;
          if (isAssigned) {
            assigned++;
            if (cData['phDone'] == true && cData['conductivityDone'] == true) {
              completed++;
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _total = total;
          _assigned = assigned;
          _completed = completed;
          _loaded = true;
        });

        // ── Monthly reminder for the admin ──────────────────────────────
        // Fires once per month on first open; follow-up after day 7 if
        // some users are still unassigned.
        NotificationService.instance.checkAdminMonthlyReminder(
          assignedCount: assigned,
          totalCount: total,
        );
      }
    } catch (e) {
      debugPrint('Admin overview error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.red.withOpacity(0.35), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.assignment_turned_in,
                  color: Colors.red, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Calibration Tasks — This Month',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _loaded
                        ? '$_assigned / $_total assigned  •  $_completed completed'
                        : 'Loading…',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios,
                color: Colors.white38, size: 16),
          ],
        ),
      ),
    );
  }
}
