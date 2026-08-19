import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  tz.initializeTimeZones();
  const AndroidInitializationSettings android =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings ios = DarwinInitializationSettings();
  const InitializationSettings settings =
      InitializationSettings(android: android, iOS: ios);
  await notificationsPlugin.initialize(settings: settings);
}

String _getInitial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
}

abstract class AppRole {
  static const admin = 'admin';
  static const user = 'user';
  static bool isAdmin(String role) => role.contains(admin);
}

class AdminCalibrationScreen extends StatefulWidget {
  const AdminCalibrationScreen({super.key});

  @override
  State<AdminCalibrationScreen> createState() => _AdminCalibrationScreenState();
}

class _AdminCalibrationScreenState extends State<AdminCalibrationScreen> {
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _isLoading = true;
  String _selectedMonth = '';

  // ✅ NEW: shared calibration status for the selected month
  Map<String, dynamic> _sharedStatus = {};

  final TextEditingController _searchCtrl = TextEditingController();
  int _filterTab = 0;

  @override
  void initState() {
    super.initState();
    _selectedMonth = _currentMonth;
    _searchCtrl.addListener(_applyFilter);
    _initNotifications();
    _loadUsers();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _currentMonth {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  List<String> get _monthOptions {
    final now = DateTime.now();
    return List.generate(6, (i) {
      final d = DateTime(now.year, now.month - i, 1);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}';
    });
  }

  String _formatMonthLabel(String m) {
    final parts = m.split('-');
    if (parts.length != 2) return m;
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
      'December'
    ];
    final idx = int.tryParse(parts[1]) ?? 0;
    return '${months[idx]} ${parts[0]}';
  }

  String _formatDate(int? ms) {
    if (ms == null) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  // ✅ Counts based on assignment only (done status is now shared/global)
  int get _assignedCount =>
      _allUsers.where((u) => u['assigned'] as bool).length;
  bool get _phDone => _sharedStatus['phDone'] == true;
  bool get _condDone => _sharedStatus['conductivityDone'] == true;
  bool get _allDone => _phDone && _condDone;

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      // ✅ Load shared calibration status for the month
      final sharedSnap = await FirebaseDatabase.instance
          .ref('calibrationShared/$_selectedMonth')
          .get();
      final shared = (sharedSnap.exists && sharedSnap.value is Map)
          ? Map<String, dynamic>.from(sharedSnap.value as Map)
          : <String, dynamic>{};

      final usersSnap = await FirebaseDatabase.instance.ref('users').get();
      if (!usersSnap.exists || usersSnap.value is! Map) {
        setState(() {
          _sharedStatus = shared;
          _isLoading = false;
        });
        return;
      }

      final usersData = usersSnap.value as Map<dynamic, dynamic>;
      final List<Map<String, dynamic>> result = [];

      for (final entry in usersData.entries) {
        final uid = entry.key.toString();
        final uData = entry.value;

        if (uData is! Map) continue;
        final rawName = uData['name']?.toString() ?? '';
        final rawEmail = uData['email']?.toString() ?? '';
        if (rawName.trim().isEmpty && rawEmail.trim().isEmpty) continue;

        final rawRole = uData['role'] ?? uData['userRole'] ?? uData['type'];
        final role = rawRole?.toString().toLowerCase() ?? AppRole.user;
        if (AppRole.isAdmin(role)) continue;

        // ✅ Only load assignment info per user (done status is global now)
        final calibSnap = await FirebaseDatabase.instance
            .ref('calibrations/$uid/$_selectedMonth')
            .get();

        bool assigned = false;
        int? assignedAt;

        if (calibSnap.exists && calibSnap.value is Map) {
          final cData = calibSnap.value as Map<dynamic, dynamic>;
          assigned = cData['assignedBy']?.toString().isNotEmpty == true;
          assignedAt =
              cData['assignedAt'] is int ? cData['assignedAt'] as int : null;
        }

        final String safeName =
            rawName.trim().isEmpty ? 'Unknown' : rawName.trim();

        result.add({
          'uid': uid,
          'name': safeName,
          'email': rawEmail,
          'assigned': assigned,
          'assignedAt': assignedAt,
        });
      }

      result.sort((a, b) {
        if ((a['assigned'] as bool) && !(b['assigned'] as bool)) return -1;
        if (!(a['assigned'] as bool) && (b['assigned'] as bool)) return 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      setState(() {
        _allUsers = result;
        _sharedStatus = shared;
        _isLoading = false;
      });
      _applyFilter();
    } catch (e) {
      debugPrint('Error loading users: $e');
      setState(() => _isLoading = false);
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _allUsers.where((u) {
        final matchSearch = q.isEmpty ||
            (u['name'] as String).toLowerCase().contains(q) ||
            (u['email'] as String).toLowerCase().contains(q);
        final bool assigned = u['assigned'] as bool;
        final matchTab = switch (_filterTab) {
          1 => assigned,
          2 => !assigned,
          _ => true,
        };
        return matchSearch && matchTab;
      }).toList();
    });
  }

  void _setFilterTab(int tab) {
    setState(() => _filterTab = tab);
    _applyFilter();
  }

  Future<void> _assignTask(Map<String, dynamic> user) async {
    // ✅ If all tasks are globally done, warn admin
    if (_allDone) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('All Tasks Completed'),
          content: const Text(
            'Both calibration tasks are already completed for this month.\n'
            'Do you still want to assign this user?',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign Anyway')),
          ],
        ),
      );
      if (confirm != true) return;
    }

    try {
      final adminUid = FirebaseAuth.instance.currentUser!.uid;
      await FirebaseDatabase.instance
          .ref('calibrations/${user['uid']}/$_selectedMonth')
          .update({
        'assignedBy': adminUid,
        'assignedAt': ServerValue.timestamp,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Task assigned to ${user['name']}')),
        );
      }
      await _loadUsers();
    } catch (e) {
      debugPrint('Assign error: $e');
    }
  }

  Future<void> _unassignTask(Map<String, dynamic> user) async {
    await FirebaseDatabase.instance
        .ref('calibrations/${user['uid']}/$_selectedMonth')
        .remove();
    await _loadUsers();
  }

  // ✅ NEW: Admin can reset shared task status (re-open for everyone)
  Future<void> _resetSharedTask(String taskKey, String taskLabel) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Task'),
        content: Text(
          'This will reset "$taskLabel" for ALL users this month.\n'
          'Everyone will need to redo this task. Continue?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await FirebaseDatabase.instance
        .ref('calibrationShared/$_selectedMonth')
        .update({
      taskKey: false,
      '${taskKey}By': null,
      '${taskKey}ByName': null,
      '${taskKey}At': null,
    });
    await _loadUsers();
  }

  Future<void> _assignAll() async {
    final unassigned =
        _allUsers.where((u) => !(u['assigned'] as bool)).toList();
    if (unassigned.isEmpty) return;
    for (final u in unassigned) {
      await _assignTask(u);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibration Management'),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadUsers),
          if (!_isLoading && _allUsers.any((u) => !(u['assigned'] as bool)))
            IconButton(
                icon: const Icon(Icons.assignment_turned_in_outlined),
                onPressed: _assignAll),
        ],
      ),
      body: Column(
        children: [
          _buildMonthSelector(),
          if (!_isLoading)
            _buildSharedStatusCard(), // ✅ NEW global status banner
          if (!_isLoading) _buildStatsRow(),
          if (!_isLoading) _buildFilterTabs(),
          const SizedBox(height: 4),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? const Center(
                        child: Text('No users found',
                            style: TextStyle(color: Colors.grey)))
                    : RefreshIndicator(
                        onRefresh: _loadUsers,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: _filtered.length,
                          itemBuilder: (ctx, i) => _buildUserCard(_filtered[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  // ✅ NEW: Global shared status banner shown at top
  Widget _buildSharedStatusCard() {
    final phDoneByName = _sharedStatus['phDoneByName']?.toString() ?? '';
    final condDoneByName =
        _sharedStatus['conductivityDoneByName']?.toString() ?? '';
    final phDoneAt = _sharedStatus['phDoneAt'] is int
        ? _sharedStatus['phDoneAt'] as int
        : null;
    final condDoneAt = _sharedStatus['conductivityDoneAt'] is int
        ? _sharedStatus['conductivityDoneAt'] as int
        : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _allDone ? Colors.green.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _allDone ? Colors.green.shade300 : Colors.blue.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _allDone ? Icons.lock : Icons.info_outline,
                color: _allDone ? Colors.green : Colors.blue,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                _allDone
                    ? 'All tasks completed — Locked for all users'
                    : 'Shared Calibration Status',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color:
                      _allDone ? Colors.green.shade800 : Colors.blue.shade800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _buildSharedTaskRow(
            icon: Icons.science,
            label: 'pH Sensor',
            isDone: _phDone,
            doneByName: phDoneByName,
            doneAt: phDoneAt,
            onReset: () => _resetSharedTask('phDone', 'pH Sensor'),
          ),
          const SizedBox(height: 6),
          _buildSharedTaskRow(
            icon: Icons.electrical_services,
            label: 'Conductivity Sensor',
            isDone: _condDone,
            doneByName: condDoneByName,
            doneAt: condDoneAt,
            onReset: () =>
                _resetSharedTask('conductivityDone', 'Conductivity Sensor'),
          ),
        ],
      ),
    );
  }

  Widget _buildSharedTaskRow({
    required IconData icon,
    required String label,
    required bool isDone,
    required String doneByName,
    required int? doneAt,
    required VoidCallback onReset,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: isDone ? Colors.green : Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 13)),
              if (isDone && doneByName.isNotEmpty)
                Text(
                  'By $doneByName  •  ${_formatDate(doneAt)}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
            ],
          ),
        ),
        if (isDone)
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Reset', style: TextStyle(fontSize: 12)),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('Pending',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
          ),
      ],
    );
  }

  Widget _buildMonthSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedMonth,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Month',
                  ),
                  items: _monthOptions
                      .map((m) => DropdownMenuItem<String>(
                            value: m,
                            child: Text(_formatMonthLabel(m)),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value == null || value == _selectedMonth) return;
                    setState(() => _selectedMonth = value);
                    _loadUsers();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by name or email',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _StatChip(
              label: 'Assigned', value: _assignedCount, color: Colors.blue),
          _StatChip(
              label: 'Total', value: _allUsers.length, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _buildFilterTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Expanded(
              child: _FilterTab(
                  label: 'All',
                  selected: _filterTab == 0,
                  onTap: () => _setFilterTab(0))),
          const SizedBox(width: 6),
          Expanded(
              child: _FilterTab(
                  label: 'Assigned',
                  selected: _filterTab == 1,
                  onTap: () => _setFilterTab(1))),
          const SizedBox(width: 6),
          Expanded(
              child: _FilterTab(
                  label: 'Not Assigned',
                  selected: _filterTab == 2,
                  onTap: () => _setFilterTab(2))),
        ],
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final bool assigned = user['assigned'] as bool;

    final Color statusColor = !assigned
        ? Colors.grey
        : _allDone
            ? Colors.green
            : Colors.blue;

    final String statusLabel = !assigned
        ? 'Not assigned'
        : _allDone
            ? 'All Done - Locked'
            : 'Assigned';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                  backgroundColor: statusColor.withOpacity(0.15),
                  child: Text(_getInitial(user['name'] as String),
                      style: TextStyle(
                          color: statusColor, fontWeight: FontWeight.bold))),
              title: Text(user['name'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(user['email'] as String),
              trailing: Chip(
                  label: Text(statusLabel,
                      style: TextStyle(color: statusColor, fontSize: 11)),
                  backgroundColor: statusColor.withOpacity(0.1)),
            ),
            const SizedBox(height: 8),
            if (assigned)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await _unassignTask(user);
                      },
                      icon: const Icon(Icons.remove_circle_outline,
                          color: Colors.red),
                      label: const Text('Remove',
                          style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _assignTask(user),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reassign'),
                    ),
                  ),
                ],
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _assignTask(user),
                  icon: const Icon(Icons.assignment_add),
                  label: const Text('Assign Task'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip(
      {required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: color)),
          const SizedBox(width: 6),
          Text(value.toString(),
              style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  const _FilterTab(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color:
              selected ? Theme.of(context).colorScheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
