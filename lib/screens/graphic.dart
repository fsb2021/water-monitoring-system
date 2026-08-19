// ignore_for_file: unused_element_parameter

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:water_app/screens/ChartsScreen.dart';
import 'app_background.dart';
import 'SettingsScreen.dart';
import 'dashboard_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Local data model
// ─────────────────────────────────────────────────────────────────────────────

class _DataPoint {
  final double value;
  final String timestamp; // "13/05/2026 13:26"

  const _DataPoint({required this.value, required this.timestamp});

  Map<String, dynamic> toJson() => {'v': value, 'ts': timestamp};

  factory _DataPoint.fromJson(Map<String, dynamic> j) => _DataPoint(
        value: (j['v'] as num).toDouble(),
        timestamp: j['ts'] as String,
      );

  /// "dd/MM\nHH:mm" shown on the X-axis (date on first line, time on second)
  String get timeLabel {
    final parts = timestamp.split(' ');
    if (parts.length < 2) return timestamp;
    final datePart = parts[0]; // "13/05/2026"
    final t = parts[1].split(':');
    final timePart = t.length >= 2 ? '${t[0]}:${t[1]}' : parts[1];
    // Shorten date to "dd/MM" to save space
    final dateSplit = datePart.split('/');
    final dateShort =
        dateSplit.length >= 2 ? '${dateSplit[0]}/${dateSplit[1]}' : datePart;
    return '$dateShort\n$timePart';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Live snapshot
// ─────────────────────────────────────────────────────────────────────────────

class SensorLiveData {
  final double temperature;
  final double ph;
  final double turbidite;
  final double ec;

  SensorLiveData({
    required this.temperature,
    required this.ph,
    required this.turbidite,
    required this.ec,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Graphic widget
// ─────────────────────────────────────────────────────────────────────────────

class Graphic extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const Graphic({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  @override
  State<Graphic> createState() => _GraphicState();
}

class _GraphicState extends State<Graphic> with SingleTickerProviderStateMixin {
  // ── Firebase refs — one per sensor node ───────────────────────────────────
  final DatabaseReference _ecRef = FirebaseDatabase.instance.ref('capteurs/ec');
  final DatabaseReference _phRef = FirebaseDatabase.instance.ref('capteurs/ph');
  final DatabaseReference _tempRef =
      FirebaseDatabase.instance.ref('capteurs/temp');
  final DatabaseReference _turbRef =
      FirebaseDatabase.instance.ref('capteurs/turbidite');

  static const int _maxPoints = 1000;

  // ── SharedPreferences keys ────────────────────────────────────────────────
  static const _kTemp = 'history_temp';
  static const _kPh = 'history_ph';
  static const _kEc = 'history_ec';
  static const _kTurb = 'history_turb';

  late TabController _tabController;
  int _selectedIndex = 1;

  // ── In-memory history ─────────────────────────────────────────────────────
  final List<_DataPoint> _tempHistory = [];
  final List<_DataPoint> _phHistory = [];
  final List<_DataPoint> _ecHistory = [];
  final List<_DataPoint> _turbHistory = [];

  // ── Latest raw values ─────────────────────────────────────────────────────
  double _lastTemp = 0, _lastPh = 0, _lastEc = 0, _lastTurb = 0;

  // ── Dedup — track last timestamp seen per sensor ──────────────────────────
  String _lastTempTs = '';
  String _lastPhTs = '';
  String _lastEcTs = '';
  String _lastTurbTs = '';

  // ── Live notifiers ────────────────────────────────────────────────────────
  final ValueNotifier<SensorLiveData?> _liveNotifier = ValueNotifier(null);
  final ValueNotifier<SensorLiveData?> _prevNotifier = ValueNotifier(null);

  StreamSubscription<DatabaseEvent>? _ecSub;
  StreamSubscription<DatabaseEvent>? _phSub;
  StreamSubscription<DatabaseEvent>? _tempSub;
  StreamSubscription<DatabaseEvent>? _turbSub;

  SharedPreferences? _prefs;
  bool _isLoading = true;

  // ── Tab metadata — thresholds pulled from kSensorRanges (dashboard_screen) ─
  static List<_TabMeta> get _tabs => [
        _TabMeta(
          label: 'Température',
          icon: Icons.thermostat_rounded,
          color: Color.fromARGB(255, 223, 132, 6),
          field: 'temperature',
          unit: kSensorRanges['temperature']!.unit,
          criticalMin: kSensorRanges['temperature']!.min,
          criticalMax: kSensorRanges['temperature']!.max,
        ),
        _TabMeta(
          label: 'pH',
          icon: Icons.science_rounded,
          color: Color.fromARGB(255, 7, 115, 23),
          field: 'ph',
          unit: kSensorRanges['ph']!.unit,
          criticalMin: kSensorRanges['ph']!.min,
          criticalMax: kSensorRanges['ph']!.max,
        ),
        _TabMeta(
          label: 'Turbidité',
          icon: Icons.water_rounded,
          color: Color.fromARGB(255, 1, 46, 250),
          field: 'turbidite',
          unit: ' ${kSensorRanges['turbidite']!.unit}',
          criticalMin: null,
          criticalMax: kSensorRanges['turbidite']!.max,
          criticalMinLabel: 'SEUIL BIOFILM',
        ),
        _TabMeta(
          label: 'Conductivité',
          icon: Icons.bolt_rounded,
          color: Color.fromARGB(255, 165, 15, 203),
          field: 'ec',
          unit: ' ',
          criticalMin: 3,
          criticalMax: 5,
          criticalMinLabel: 'VALEUR IDEALE',
          criticalBelowMin: false,
        ),
      ];

  // ─────────────────────────────────────────────────────────────────────────
  //  Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadCache();
    if (!mounted) return;
    _startTempListener();
    _startPhListener();
    _startEcListener();
    _startTurbListener();
    if (_tempHistory.isNotEmpty || _phHistory.isNotEmpty) {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _tempSub?.cancel();
    _phSub?.cancel();
    _ecSub?.cancel();
    _turbSub?.cancel();
    _liveNotifier.dispose();
    _prevNotifier.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Cache
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadCache() async {
    _restoreList(_kTemp, _tempHistory);
    _restoreList(_kPh, _phHistory);
    _restoreList(_kEc, _ecHistory);
    _restoreList(_kTurb, _turbHistory);

    if (_tempHistory.isNotEmpty) _lastTemp = _tempHistory.last.value;
    if (_phHistory.isNotEmpty) _lastPh = _phHistory.last.value;
    if (_ecHistory.isNotEmpty) _lastEc = _ecHistory.last.value;
    if (_turbHistory.isNotEmpty) _lastTurb = _turbHistory.last.value;

    if (_tempHistory.isNotEmpty || _phHistory.isNotEmpty) {
      _liveNotifier.value = _buildLive();
    }
  }

  void _restoreList(String key, List<_DataPoint> target) {
    final raw = _prefs?.getString(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      target.addAll(decoded.map(
          (e) => _DataPoint.fromJson(Map<String, dynamic>.from(e as Map))));
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await Future.wait([
      prefs.setString(
          _kTemp, jsonEncode(_tempHistory.map((p) => p.toJson()).toList())),
      prefs.setString(
          _kPh, jsonEncode(_phHistory.map((p) => p.toJson()).toList())),
      prefs.setString(
          _kEc, jsonEncode(_ecHistory.map((p) => p.toJson()).toList())),
      prefs.setString(
          _kTurb, jsonEncode(_turbHistory.map((p) => p.toJson()).toList())),
    ]);
  }

  Future<void> _clearCache() async {
    await Future.wait([
      _prefs?.remove(_kTemp) ?? Future.value(),
      _prefs?.remove(_kPh) ?? Future.value(),
      _prefs?.remove(_kEc) ?? Future.value(),
      _prefs?.remove(_kTurb) ?? Future.value(),
    ]);
    setState(() {
      _tempHistory.clear();
      _phHistory.clear();
      _ecHistory.clear();
      _turbHistory.clear();
    });
  }

  Future<void> _confirmAndClearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Effacer l\'historique ?'),
        content: const Text('Toutes les données locales seront supprimées. '
            'Les nouvelles mesures continueront d\'être enregistrées.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('Effacer', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm == true) await _clearCache();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Firebase listeners
  //  Each node: { date, time, value }
  // ─────────────────────────────────────────────────────────────────────────

  void _startTempListener() {
    _tempSub = _tempRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;

      final value = _parseDouble(snap.child('value').value);
      final ts = _resolveTimestamp(snap);

      if (ts == _lastTempTs && _lastTempTs.isNotEmpty) return;
      _lastTemp = value;
      _lastTempTs = ts;

      setState(() {
        _addPoint(_tempHistory, value, ts);
        _isLoading = false;
      });
      _updateLiveNotifier();
      _saveCache();
    }, onError: (e) => debugPrint('Temp stream error: $e'));
  }

  void _startPhListener() {
    _phSub = _phRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;

      final value = _parseDouble(snap.child('value').value);
      final ts = _resolveTimestamp(snap);

      if (ts == _lastPhTs && _lastPhTs.isNotEmpty) return;
      _lastPh = value;
      _lastPhTs = ts;

      setState(() {
        _addPoint(_phHistory, value, ts);
        _isLoading = false;
      });
      _updateLiveNotifier();
      _saveCache();
    }, onError: (e) => debugPrint('pH stream error: $e'));
  }

  void _startEcListener() {
    _ecSub = _ecRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;

      final value = _parseDouble(snap.child('value').value);
      final ts = _resolveTimestamp(snap);

      if (ts == _lastEcTs && _lastEcTs.isNotEmpty) return;
      _lastEc = value;
      _lastEcTs = ts;

      setState(() {
        _addPoint(_ecHistory, value, ts);
        _isLoading = false;
      });
      _updateLiveNotifier();
      _saveCache();
    }, onError: (e) => debugPrint('EC stream error: $e'));
  }

  void _startTurbListener() {
    _turbSub = _turbRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;

      final value = _parseDouble(snap.child('value').value);
      final ts = _resolveTimestamp(snap);

      if (ts == _lastTurbTs && _lastTurbTs.isNotEmpty) return;
      _lastTurb = value;
      _lastTurbTs = ts;

      setState(() {
        _addPoint(_turbHistory, value, ts);
        _isLoading = false;
      });
      _updateLiveNotifier();
      _saveCache();
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
    if (ts.isNotEmpty && ts != 'null') return ts;

    // 3️⃣  legacy epoch fallback
    return _epochToString(snap.child('timestamp').value);
  }

  String _epochToString(dynamic raw) {
    if (raw == null) return '';
    int? ms;
    if (raw is int) {
      ms = raw;
    } else if (raw is double)
      ms = raw.toInt();
    else
      ms = int.tryParse(raw.toString());
    if (ms == null || ms == 0) return '';
    if (ms < 1_000_000_000) ms *= 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Helpers
  // ─────────────────────────────────────────────────────────────────────────

  void _addPoint(List<_DataPoint> list, double value, String ts) {
    list.add(_DataPoint(value: value, timestamp: ts));
    if (list.length > _maxPoints) list.removeAt(0);
  }

  SensorLiveData _buildLive() => SensorLiveData(
        temperature: _lastTemp,
        ph: _lastPh,
        turbidite: _lastTurb,
        ec: _lastEc,
      );

  void _updateLiveNotifier() {
    _prevNotifier.value = _liveNotifier.value;
    _liveNotifier.value = _buildLive();
  }

  double _parseDouble(dynamic v) =>
      double.tryParse(v?.toString() ?? '0') ?? 0.0;

  List<FlSpot> _toSpots(List<_DataPoint> h) =>
      List.generate(h.length, (i) => FlSpot(i.toDouble(), h[i].value));

  List<String> _toXLabels(List<_DataPoint> h) =>
      h.map((p) => p.timeLabel).toList();

  String _latestTs(List<_DataPoint> h) => h.isNotEmpty ? h.last.timestamp : '';

  // ─────────────────────────────────────────────────────────────────────────
  //  Navigation
  // ─────────────────────────────────────────────────────────────────────────

  void _onBottomNavTap(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    switch (index) {
      case 0:
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => DashboardScreen(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
        return;
      case 1:
        return;
      case 2:
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ChartsScreen(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
        return;
      case 3:
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => SettingsScreen(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
        return;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Tab order matches _tabs: temp, ph, turb, ec
    final histories = [_tempHistory, _phHistory, _turbHistory, _ecHistory];

    return Scaffold(
      body: Column(
        children: [
          _buildTabBar(context),
          Expanded(
            child: AppBackground(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tabController,
                      children: List.generate(
                        _tabs.length,
                        (i) => _ChartTab(
                          spots: _toSpots(histories[i]),
                          xLabels: _toXLabels(histories[i]),
                          latestTimestamp: _latestTs(histories[i]),
                          meta: _tabs[i],
                          liveDataNotifier: _liveNotifier,
                          prevLiveDataNotifier: _prevNotifier,
                          onClearHistoryPressed: _confirmAndClearHistory,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
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
          unselectedItemColor: const Color.fromARGB(183, 40, 38, 38),
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home), label: ''),
            BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: ''),
            BottomNavigationBarItem(
                icon: Icon(Icons.add_box_outlined), label: ''),
            BottomNavigationBarItem(icon: Icon(Icons.settings), label: ''),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    const navBg = Color.fromARGB(255, 5, 2, 94);
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) {
        return Container(
          color: navBg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: List.generate(_tabs.length, (i) {
              final c = _tabs[i].color;
              final isActive = _tabController.index == i;
              return Expanded(
                child: GestureDetector(
                  onTap: () => _tabController.animateTo(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isActive ? c : c.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: isActive ? c : c.withOpacity(0.35),
                          width: 1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_tabs[i].icon,
                            size: 22,
                            color:
                                isActive ? Colors.white : c.withOpacity(0.75)),
                        const SizedBox(height: 4),
                        Text(_tabs[i].label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight:
                                  isActive ? FontWeight.bold : FontWeight.w500,
                              color:
                                  isActive ? Colors.white : c.withOpacity(0.75),
                            )),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tab metadata
// ─────────────────────────────────────────────────────────────────────────────

class _TabMeta {
  final String label;
  final IconData icon;
  final Color color;
  final String field;
  final String unit;
  final double? criticalMin;
  final double? criticalMax;
  final String criticalMinLabel;
  final String criticalMaxLabel;
  final bool criticalBelowMin;

  const _TabMeta({
    required this.label,
    required this.icon,
    required this.color,
    required this.field,
    required this.unit,
    this.criticalMin,
    this.criticalMax,
    this.criticalMinLabel = 'MIN CRITIQUE',
    this.criticalMaxLabel = 'MAX CRITIQUE',
    this.criticalBelowMin = true,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  Chart tab
// ─────────────────────────────────────────────────────────────────────────────

class _ChartTab extends StatelessWidget {
  final List<FlSpot> spots;
  final List<String> xLabels;
  final String latestTimestamp;
  final _TabMeta meta;
  final ValueNotifier<SensorLiveData?> liveDataNotifier;
  final ValueNotifier<SensorLiveData?> prevLiveDataNotifier;
  final Future<void> Function() onClearHistoryPressed;

  const _ChartTab({
    required this.spots,
    required this.xLabels,
    required this.latestTimestamp,
    required this.meta,
    required this.liveDataNotifier,
    required this.prevLiveDataNotifier,
    required this.onClearHistoryPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (spots.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(meta.icon, size: 48, color: meta.color.withOpacity(0.35)),
            const SizedBox(height: 12),
            Text('En attente de données…',
                style: TextStyle(
                    fontSize: 15,
                    color: meta.color.withOpacity(0.55),
                    fontWeight: FontWeight.w500)),
          ],
        ),
      );
    }

    final values = spots.map((s) => s.y).toList();
    final minVal = values.reduce((a, b) => a < b ? a : b);
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final avg = values.reduce((a, b) => a + b) / values.length;
    final isCond = meta.field == 'ec';

    final minRef =
        meta.criticalMin == null ? minVal : math.min(minVal, meta.criticalMin!);
    final maxRef =
        meta.criticalMax == null ? maxVal : math.max(maxVal, meta.criticalMax!);

    // ── Precise, "nice" axis bounds ────---------------------------------
    // Instead of an arbitrary range/4 interval (which produces ugly ticks
    // like 7.83 that don't line up with gridlines), snap the tick interval
    // to a round number and snap min/max to exact multiples of it. This
    // keeps every gridline label, data point, and critical threshold line
    // aligned to the same precise scale instead of drifting independently.
    final rawSpan = (maxRef - minRef).abs().clamp(0.01, double.infinity);
    final rawInterval = rawSpan / 4;
    final hInterval = _niceInterval(rawInterval);

    final minY =
        (math.min(minRef, minRef - hInterval * 0.001) / hInterval).floor() *
            hInterval;
    final maxY =
        (math.max(maxRef, maxRef + hInterval * 0.001) / hInterval).ceil() *
            hInterval;
    // Guard against a degenerate (flat-line) series.
    final safeMaxY = (maxY <= minY) ? minY + hInterval : maxY;

    final leftReserved =
        (_formatY(safeMaxY).length * 7.5 + 8).clamp(42.0, 76.0);
    final xStep = (spots.length / 5).ceil().clamp(1, spots.length);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Live header ──────────────────────────────────────────────────
          ValueListenableBuilder<SensorLiveData?>(
            valueListenable: liveDataNotifier,
            builder: (_, live, __) => ValueListenableBuilder<SensorLiveData?>(
              valueListenable: prevLiveDataNotifier,
              builder: (_, prev, __) {
                final last = _fieldValue(live, meta.field);
                final prevV = _fieldValue(prev, meta.field);
                final trend = _trend(last, prevV);
                final isCritical = last != null &&
                    ((meta.criticalBelowMin &&
                            meta.criticalMin != null &&
                            last < meta.criticalMin!) ||
                        (meta.criticalMax != null && last > meta.criticalMax!));

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                _LiveBadge(color: meta.color),
                                const SizedBox(width: 10),
                                if (last != null) ...[
                                  Text('${last.toStringAsFixed(2)}${meta.unit}',
                                      style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: isCritical
                                              ? Colors.redAccent
                                              : meta.color)),
                                  const SizedBox(width: 8),
                                  _TrendIcon(trend: trend),
                                  const SizedBox(width: 12),
                                  _StatusBadge(isCritical: isCritical),
                                ],
                              ]),
                              if (latestTimestamp.isNotEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 8, left: 2),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: meta.color.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: meta.color.withOpacity(0.25),
                                          width: 1),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.access_time,
                                            size: 14,
                                            color: meta.color.withOpacity(0.7)),
                                        const SizedBox(width: 6),
                                        Text(latestTimestamp,
                                            style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: meta.color
                                                    .withOpacity(0.85))),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),

          const SizedBox(height: 14),

          // ── Graph range box ─────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: meta.color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: meta.color.withOpacity(0.22)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Min',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text('${minVal.toStringAsFixed(2)}${meta.unit}',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: meta.color)),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 34,
                  color: meta.color.withOpacity(0.22),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Max',
                            style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('${maxVal.toStringAsFixed(2)}${meta.unit}',
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.redAccent)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),
          Align(
            alignment: Alignment.center,
            child: OutlinedButton.icon(
              onPressed: onClearHistoryPressed,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('Effacer l\'historique local'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red.shade700,
                side: BorderSide(color: Colors.red.shade300),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),

          const SizedBox(height: 20),

          // ── Line chart ───────────────────────────────────────────────────
          Expanded(
            child: LineChart(
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              LineChartData(
                minY: minY,
                maxY: safeMaxY,
                extraLinesData: ExtraLinesData(horizontalLines: [
                  HorizontalLine(
                    y: maxVal,
                    color: meta.color.withOpacity(0.9),
                    strokeWidth: 2.5,
                    dashArray: [10, 4],
                    label: HorizontalLineLabel(
                      show: true,
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.only(right: 12, top: 4),
                      style: TextStyle(
                        color: meta.color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                      labelResolver: (_) =>
                          'MAX (${_formatY(maxVal)}${meta.unit})',
                    ),
                  ),
                  if (meta.criticalMax != null && meta.field != 'ec')
                    HorizontalLine(
                      y: meta.criticalMax!,
                      color: Colors.redAccent.withOpacity(0.85),
                      strokeWidth: 2.5,
                      dashArray: [8, 4],
                      label: HorizontalLineLabel(
                        show: true,
                        alignment: Alignment.topLeft,
                        padding: const EdgeInsets.only(left: 12, top: 4),
                        style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        labelResolver: (_) =>
                            '${meta.criticalMaxLabel} (${_formatY(meta.criticalMax!)}${meta.unit})',
                      ),
                    ),
                  if (meta.criticalMin != null)
                    HorizontalLine(
                      y: meta.criticalMin!,
                      color: const Color.fromARGB(255, 10, 163, 23)
                          .withOpacity(0.85),
                      strokeWidth: 2.5,
                      dashArray: [8, 4],
                      label: HorizontalLineLabel(
                        show: true,
                        alignment: Alignment.bottomRight,
                        padding: const EdgeInsets.only(right: 12, bottom: 4),
                        style: const TextStyle(
                            color: Color.fromARGB(255, 68, 255, 84),
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                        labelResolver: (_) =>
                            '${meta.criticalMinLabel} (${_formatY(meta.criticalMin!)}${meta.unit})',
                      ),
                    ),
                ]),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  horizontalInterval: hInterval,
                  verticalInterval: xStep.toDouble(),
                  getDrawingHorizontalLine: (_) => FlLine(
                      color: const Color.fromARGB(255, 13, 12, 12)
                          .withOpacity(0.18),
                      strokeWidth: 1),
                  getDrawingVerticalLine: (_) => FlLine(
                      color:
                          const Color.fromARGB(255, 8, 7, 7).withOpacity(0.10),
                      strokeWidth: 1,
                      dashArray: [4, 4]),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border(
                    bottom: BorderSide(
                        color: const Color.fromARGB(255, 82, 80, 80)
                            .withOpacity(0.35),
                        width: 1),
                    left: BorderSide(
                        color: const Color.fromARGB(255, 89, 88, 88)
                            .withOpacity(0.35),
                        width: 1),
                    right: BorderSide.none,
                    top: BorderSide.none,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 48, // taller to fit two lines (date + time)
                      interval: xStep.toDouble(),
                      getTitlesWidget: (value, _) {
                        final idx = value.toInt();
                        if (idx < 0 || idx >= xLabels.length) {
                          return const SizedBox.shrink();
                        }
                        // Only show a label if this index falls exactly on
                        // the chosen step, so the tick position always
                        // matches a real data point.
                        if (idx % xStep != 0 && idx != xLabels.length - 1) {
                          return const SizedBox.shrink();
                        }
                        // xLabels[idx] is "dd/MM\nHH:mm"
                        final lines = xLabels[idx].split('\n');
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                lines[0], // "dd/MM"
                                style: const TextStyle(
                                    fontSize: 8,
                                    color: Color.fromARGB(255, 200, 198, 198)),
                              ),
                              Text(
                                lines.length > 1 ? lines[1] : '', // "HH:mm"
                                style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: Color.fromARGB(255, 240, 239, 239)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: leftReserved,
                      interval: hInterval,
                      getTitlesWidget: (value, _) => Text(_formatY(value),
                          style: const TextStyle(
                              fontSize: 10,
                              color: Color.fromARGB(255, 227, 222, 222))),
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  handleBuiltInTouches: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => meta.color.withOpacity(0.88),
                    tooltipRoundedRadius: 8,
                    getTooltipItems: (touched) => touched.map((s) {
                      final ts = s.spotIndex < xLabels.length
                          ? '\n${xLabels[s.spotIndex].replaceAll('\n', ' ')}'
                          : '';
                      return LineTooltipItem(
                        '${s.y.toStringAsFixed(2)}${meta.unit}$ts',
                        const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      );
                    }).toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    // Lower smoothness + overshoot prevention keeps the
                    // curve from bulging past the real value at each point,
                    // so the visual line always tracks the true reading.
                    curveSmoothness: 0.15,
                    preventCurveOverShooting: true,
                    preventCurveOvershootingThreshold: 1.0,
                    isStrokeCapRound: true,
                    color: meta.color,
                    barWidth: 3,
                    // Explicit dots pin every value to its exact plotted
                    // position instead of leaving it implicit on the curve.
                    dotData: FlDotData(
                      show: true,
                      checkToShowDot: (spot, barData) =>
                          spots.length <= 30 ||
                          spot.x.toInt() % xStep == 0 ||
                          spot == spots.last,
                      getDotPainter: (spot, percent, bar, index) =>
                          FlDotCirclePainter(
                        radius: 3,
                        color: meta.color,
                        strokeWidth: 1.5,
                        strokeColor: Colors.white,
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          meta.color.withOpacity(0.30),
                          meta.color.withOpacity(0.02),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  double? _fieldValue(SensorLiveData? d, String f) {
    if (d == null) return null;
    switch (f) {
      case 'temperature':
        return d.temperature;
      case 'ph':
        return d.ph;
      case 'turbidite':
        return d.turbidite;
      case 'ec':
        return d.ec;
      default:
        return null;
    }
  }

  int _trend(double? last, double? prev) {
    if (last == null || prev == null) return 0;
    final d = last - prev;
    if (d.abs() < 0.01) return 0;
    return d > 0 ? 1 : -1;
  }

  /// Rounds [rough] up to a "nice" number (1, 2, 2.5, 5, 10 × 10^n) so axis
  /// ticks land on clean, readable values instead of arbitrary decimals.
  double _niceInterval(double rough) {
    if (rough <= 0) return 1;
    final exponent = (math.log(rough) / math.ln10).floor();
    final magnitude = math.pow(10, exponent).toDouble();
    final fraction = rough / magnitude;
    double niceFraction;
    if (fraction <= 1) {
      niceFraction = 1;
    } else if (fraction <= 2) {
      niceFraction = 2;
    } else if (fraction <= 2.5) {
      niceFraction = 2.5;
    } else if (fraction <= 5) {
      niceFraction = 5;
    } else {
      niceFraction = 10;
    }
    return niceFraction * magnitude;
  }

  String _formatY(double v) {
    if (v.abs() >= 100) return v.toStringAsFixed(0);
    if (v.abs() >= 10) return v.toStringAsFixed(1);
    final s = v.toStringAsFixed(2);
    return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Small reusable widgets
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final bool isCritical;
  const _StatusBadge({required this.isCritical});
  @override
  Widget build(BuildContext context) {
    final color = isCritical ? Colors.redAccent : Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
            isCritical
                ? Icons.warning_amber_rounded
                : Icons.check_circle_rounded,
            size: 18,
            color: color),
        const SizedBox(width: 6),
        Text(isCritical ? 'CRITIQUE' : 'NORMAL',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}

class _LiveBadge extends StatefulWidget {
  final Color color;
  const _LiveBadge({required this.color});
  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.25, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      FadeTransition(
        opacity: _anim,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: widget.color.withOpacity(0.55),
                  blurRadius: 6,
                  spreadRadius: 1)
            ],
          ),
        ),
      ),
      const SizedBox(width: 5),
      Text('LIVE',
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: widget.color,
              letterSpacing: 1.3)),
    ]);
  }
}

class _TrendIcon extends StatelessWidget {
  final int trend;
  const _TrendIcon({required this.trend});
  @override
  Widget build(BuildContext context) {
    final icon = trend == 1
        ? Icons.arrow_upward_rounded
        : trend == -1
            ? Icons.arrow_downward_rounded
            : Icons.remove_rounded;
    final color = trend == 1
        ? Colors.redAccent
        : trend == -1
            ? const Color.fromARGB(255, 11, 31, 65)
            : const Color.fromARGB(255, 209, 220, 11);
    return Icon(icon, size: 20, color: color);
  }
}

class _StatChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _StatChip(
      {required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.28)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}
