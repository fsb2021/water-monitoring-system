import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:water_app/screens/auth/login_screen.dart';
import 'package:water_app/screens/common/app_background.dart';
import 'package:water_app/screens/monitoring/charts_screen.dart';
import 'package:water_app/screens/monitoring/dashboard_screen.dart';
import 'package:water_app/screens/monitoring/graphic.dart';
import 'package:water_app/screens/settings/notification_management_screen.dart';
import 'package:water_app/translations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Realtime Database layout
//
//  users/
//    {uid}/
//      role: "admin" | "user"
//      name: "Alice"
//      email: "alice@example.com"
//      notifications/
//        app: true | false
//
//  settings/
//    sensor_delays/
//      temperature:  60      ← always stored in minutes
//      conductivity: 60
//      ph:           60
//      turbidity:    60
//      updatedAt:    <timestamp ms>
//      updatedBy:    "{uid}"
// ─────────────────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  final Locale? currentLocale;
  final Function(Locale)? onLocaleChanged;

  const SettingsScreen({
    super.key,
    this.currentLocale,
    this.onLocaleChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // ── Sensor delays (in minutes) ──────────────────────────────────────────
  int _temperatureDelay = 60;
  int _conductivityDelay = 60;
  int _phDelay = 60;
  int _turbidityDelay = 60;

  // ── Admin state ──────────────────────────────────────────────────────────
  bool _isAdmin = false;
  bool _isLoadingAdmin = true;
  bool _isSaving = false;

  // ── Other settings ───────────────────────────────────────────────────────
  late String _languageCode;
  int _selectedIndex = 3;

  final Translations _translations = Translations();

  // ── Realtime Database root reference ────────────────────────────────────
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // ── Time options: 1 min → 48 h ──────────────────────────────────────────
  static final List<int> _timeOptions = _buildTimeOptions();

  static List<int> _buildTimeOptions() {
    return [
      1,
      2,
      5,
      10,
      15,
      20,
      30,
      45,
      ...List.generate(48, (i) => (i + 1) * 60),
    ];
  }

  String _formatDuration(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }

  // ── Life-cycle ───────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    final locale = widget.currentLocale ?? const Locale('en');
    _translations.setLocale(locale);
    _languageCode = locale.languageCode;
    _checkAdminAndLoadDelays();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final locale = widget.currentLocale ?? const Locale('en');
    if (locale.languageCode != _languageCode) {
      _translations.setLocale(locale);
      setState(() => _languageCode = locale.languageCode);
    }
  }

  // ── Firebase helpers ─────────────────────────────────────────────────────

  Future<void> _checkAdminAndLoadDelays() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isAdmin = false;
        _isLoadingAdmin = false;
      });
      return;
    }

    try {
      // 1 ── Read role: users/{uid}/role
      final roleSnap = await _db.child('users/${user.uid}/role').get();
      final isAdmin = roleSnap.value == 'admin';

      // 2 ── Read existing delays: settings/sensor_delays
      final delaySnap = await _db.child('settings/sensor_delays').get();

      if (delaySnap.exists && delaySnap.value != null) {
        final d = Map<String, dynamic>.from(delaySnap.value as Map);
        setState(() {
          _temperatureDelay = (d['temperature'] as num?)?.toInt() ?? 60;
          _conductivityDelay = (d['conductivity'] as num?)?.toInt() ?? 60;
          _phDelay = (d['ph'] as num?)?.toInt() ?? 60;
          _turbidityDelay = (d['turbidity'] as num?)?.toInt() ?? 60;
        });
      }

      setState(() {
        _isAdmin = isAdmin;
        _isLoadingAdmin = false;
      });
    } catch (_) {
      setState(() {
        _isAdmin = false;
        _isLoadingAdmin = false;
      });
    }
  }

  Future<void> _saveDelaysToFirebase() async {
    setState(() => _isSaving = true);
    try {
      // update() writes only the given keys, leaving siblings untouched
      await _db.child('settings/sensor_delays').update({
        'temperature': _temperatureDelay,
        'conductivity': _conductivityDelay,
        'ph': _phDelay,
        'turbidity': _turbidityDelay,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_translate('settings_saved')),
          backgroundColor: const Color.fromARGB(255, 8, 118, 173),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Translation helper ───────────────────────────────────────────────────
  String _translate(String key) {
    _translations.setLocale(Localizations.localeOf(context));
    return _translations.translate(key);
  }

  String _languageLabel(String code) {
    switch (code) {
      case 'fr':
        return 'français';
      case 'ar':
        return 'العربية';
      case 'de':
        return 'deutsch';
      default:
        return 'english';
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 40, bottom: 50),
                child: Text(
                  _translate('settings'),
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w300,
                    color: Colors.white,
                  ),
                ),
              ),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSettingRow(
                        label: _translate('language'),
                        value: _languageCode,
                        items: const ['en', 'fr', 'ar', 'de'],
                        onChanged: (val) {
                          if (val != null) {
                            final newLocale = Locale(val);
                            _translations.setLocale(newLocale);
                            setState(() => _languageCode = val);
                            widget.onLocaleChanged?.call(newLocale);
                          }
                        },
                        itemLabelBuilder: _languageLabel,
                      ),
                      const SizedBox(height: 20),
                      const SizedBox(height: 36),
                      _buildSensorDelaySection(),
                    ],
                  ),
                ),
              ),

              // ── Disconnect button ────────────────────────────────────
              Container(
                width: double.infinity,
                color: const Color.fromARGB(255, 16, 92, 168)
                    .withValues(alpha: 0.25),
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: GestureDetector(
                  onTap: _showDisconnectDialog,
                  child: Text(
                    _translate('disconnected'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color.fromARGB(255, 248, 249, 250),
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // ── Sensor delay section ─────────────────────────────────────────────────
  Widget _buildSensorDelaySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.timer_outlined,
                color: Colors.cyanAccent, size: 20),
            const SizedBox(width: 8),
            Text(
              _translate('measure_delay'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 8),
            if (!_isAdmin)
              const Icon(Icons.lock, color: Colors.white38, size: 16),
          ],
        ),
        const SizedBox(height: 6),
        if (_isLoadingAdmin)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.cyanAccent),
            ),
          )
        else if (_isAdmin)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.cyanAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: Colors.cyanAccent.withValues(alpha: 0.4)),
            ),
            child: Text(
              _translate('admin_mode'),
              style: const TextStyle(
                color: Colors.cyanAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _translate('admin_only_delay'),
              style: const TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ),
        _buildDelayRow(
          icon: Icons.thermostat,
          label: _translate('temperature'),
          value: _temperatureDelay,
          onChanged:
              _isAdmin ? (v) => setState(() => _temperatureDelay = v!) : null,
        ),
        const SizedBox(height: 20),
        _buildDelayRow(
          icon: Icons.electrical_services,
          label: _translate('conductivity'),
          value: _conductivityDelay,
          onChanged:
              _isAdmin ? (v) => setState(() => _conductivityDelay = v!) : null,
        ),
        const SizedBox(height: 20),
        _buildDelayRow(
          icon: Icons.science,
          label: 'pH',
          value: _phDelay,
          onChanged: _isAdmin ? (v) => setState(() => _phDelay = v!) : null,
        ),
        const SizedBox(height: 20),
        _buildDelayRow(
          icon: Icons.water,
          label: _translate('turbidity'),
          value: _turbidityDelay,
          onChanged:
              _isAdmin ? (v) => setState(() => _turbidityDelay = v!) : null,
        ),
        const SizedBox(height: 28),
        if (_isAdmin) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSaving ? null : _saveDelaysToFirebase,
              icon: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save_alt_rounded),
              label: Text(
                _isSaving ? _translate('saving') : _translate('save_delays'),
                style:
                    const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 8, 118, 173),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NotificationManagementScreen(
                    currentLocale: Localizations.localeOf(context),
                    onLocaleChanged: widget.onLocaleChanged,
                  ),
                ),
              ),
              icon: const Icon(Icons.manage_accounts_rounded,
                  color: Colors.cyanAccent),
              label: Text(
                _translate('manage_notif_recipients'),
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side:
                    BorderSide(color: Colors.cyanAccent.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }

  // ── Single sensor delay row ──────────────────────────────────────────────
  Widget _buildDelayRow({
    required IconData icon,
    required String label,
    required int value,
    required void Function(int?)? onChanged,
  }) {
    final bool enabled = onChanged != null;

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.cyanAccent, size: 18),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 15)),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: enabled ? 0.10 : 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: enabled
                    ? Colors.white.withValues(alpha: 0.20)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DropdownButton<int>(
              value: _timeOptions.contains(value) ? value : _timeOptions.first,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              dropdownColor: const Color(0xFF1A3F7A),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              icon: Icon(
                Icons.arrow_drop_down,
                color: enabled ? Colors.cyanAccent : Colors.white24,
              ),
              items: _timeOptions
                  .map((m) => DropdownMenuItem<int>(
                        value: m,
                        child: Text(_formatDuration(m)),
                      ))
                  .toList(),
              onChanged: enabled ? onChanged : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              '= $value min',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  // ── Generic string settings row ─────────────────────────────────────────
  Widget _buildSettingRow({
    required String label,
    required String value,
    required List<String> items,
    required void Function(String?) onChanged,
    String Function(String)? itemLabelBuilder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 15)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: const Color(0xFF1A3F7A),
            style: const TextStyle(color: Colors.white, fontSize: 16),
            icon: const Icon(Icons.arrow_drop_down, color: Colors.cyanAccent),
            items: items
                .map((e) => DropdownMenuItem(
                      value: e,
                      child: Text(
                          itemLabelBuilder != null ? itemLabelBuilder(e) : e),
                    ))
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  // ── Bottom navigation ────────────────────────────────────────────────────
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
        unselectedItemColor: const Color.fromARGB(136, 47, 44, 44),
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

  void _onBottomNavTap(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    switch (index) {
      case 0:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DashboardScreen(
              currentLocale: Localizations.localeOf(context),
              onLocaleChanged: widget.onLocaleChanged ?? (_) {},
            ),
          ),
        );
        return;
      case 1:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => Graphic(
              currentLocale: Localizations.localeOf(context),
              onLocaleChanged: widget.onLocaleChanged ?? (_) {},
            ),
          ),
        );
        return;
      case 2:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChartsScreen(
              currentLocale: Localizations.localeOf(context),
              onLocaleChanged: widget.onLocaleChanged ?? (_) {},
            ),
          ),
        );
        return;
      case 3:
        return;
    }
  }

  // ── Disconnect dialog ────────────────────────────────────────────────────
  void _showDisconnectDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color.fromARGB(255, 231, 234, 238),
          title: Text(
            _translate('disconnect_title'),
            style: const TextStyle(color: Colors.white),
          ),
          content: Text(
            _translate('disconnect_confirm'),
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_translate('cancel'),
                  style: const TextStyle(color: Colors.blue)),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await FirebaseAuth.instance.signOut();
                if (!mounted) return;
                Navigator.pushReplacement(
                  this.context,
                  MaterialPageRoute(
                    builder: (_) => LoginScreen(
                      currentLocale: Localizations.localeOf(this.context),
                      onLocaleChanged: widget.onLocaleChanged ?? (_) {},
                    ),
                  ),
                );
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(_translate('disconnect_success')),
                    backgroundColor: const Color.fromARGB(255, 8, 118, 173),
                  ),
                );
              },
              child: Text(
                _translate('sign out'),
                style:
                    const TextStyle(color: Color.fromARGB(255, 77, 115, 115)),
              ),
            ),
          ],
        );
      },
    );
  }
}
