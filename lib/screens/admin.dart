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

  int get _assignedCount =>
      _allUsers.where((u) => u['assigned'] as bool).length;
  int get _completedCount => _allUsers
      .where((u) => (u['phDone'] as bool) && (u['condDone'] as bool))
      .length;
  int get _partialCount => _allUsers
      .where((u) =>
          (u['assigned'] as bool) &&
          !((u['phDone'] as bool) && (u['condDone'] as bool)))
      .length;

  bool _isCalibrationCompleted(Map<String, dynamic> user) {
    return (user['phDone'] as bool) && (user['condDone'] as bool);
  }

  // ✅ FIX: Skip users deleted from DB (null/incomplete records)
  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final usersSnap = await FirebaseDatabase.instance.ref('users').get();
      if (!usersSnap.exists || usersSnap.value is! Map) {
        setState(() => _isLoading = false);
        return;
      }

      final usersData = usersSnap.value as Map<dynamic, dynamic>;
      final List<Map<String, dynamic>> result = [];

      for (final entry in usersData.entries) {
        final uid = entry.key.toString();
        final uData = entry.value;

        // ✅ FIX 1: Skip null or non-map entries (deleted/corrupted users)
        if (uData is! Map) continue;

        // ✅ FIX 2: Skip records with no email AND no name (ghost records)
        final rawEmail = uData['email']?.toString() ?? '';
        final rawName = uData['name']?.toString() ?? '';
        if (rawEmail.isEmpty && rawName.isEmpty) continue;

        final rawRole = uData['role'] ?? uData['userRole'] ?? uData['type'];
        final role = rawRole?.toString().toLowerCase() ?? AppRole.user;
        if (AppRole.isAdmin(role)) continue;

        final calibSnap = await FirebaseDatabase.instance
            .ref('calibrations/$uid/$_selectedMonth')
            .get();

        bool assigned = false;
        bool phDone = false;
        bool condDone = false;
        int? assignedAt;
        int? phDoneAt;
        int? condDoneAt;

        if (calibSnap.exists && calibSnap.value is Map) {
          final cData = calibSnap.value as Map<dynamic, dynamic>;
          assigned = cData['assignedBy']?.toString().isNotEmpty == true;
          phDone = cData['phDone'] == true;
          condDone = cData['conductivityDone'] == true;
          assignedAt =
              cData['assignedAt'] is int ? cData['assignedAt'] as int : null;
          phDoneAt = cData['phDoneAt'] is int ? cData['phDoneAt'] as int : null;
          condDoneAt = cData['conductivityDoneAt'] is int
              ? cData['conductivityDoneAt'] as int
              : null;
        }

        final String safeName = rawName.isEmpty ? 'Unknown' : rawName.trim();

        result.add({
          'uid': uid,
          'name': safeName,
          'email': rawEmail,
          'assigned': assigned,
          'phDone': phDone,
          'condDone': condDone,
          'phDoneAt': phDoneAt,
          'condDoneAt': condDoneAt,
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
        final bool allDone = (u['phDone'] as bool) && (u['condDone'] as bool);
        final bool partial = assigned && !allDone;

        final matchTab = switch (_filterTab) {
          1 => assigned,
          2 => allDone,
          3 => partial,
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
    final bool wasCompleted = _isCalibrationCompleted(user);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Assign / Reassign'),
        content: Text(
          wasCompleted
              ? 'This calibration is already completed.\nDo you want to reassign anyway?'
              : 'Assign this month\'s calibration to ${user['name']}?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final adminUid = FirebaseAuth.instance.currentUser!.uid;
      final ref = FirebaseDatabase.instance
          .ref('calibrations/${user['uid']}/$_selectedMonth');

      if (wasCompleted) {
        await ref.update({
          'assignedBy': adminUid,
          'assignedAt': ServerValue.timestamp,
        });
      } else {
        await ref.update({
          'assignedBy': adminUid,
          'assignedAt': ServerValue.timestamp,
          'phDone': false,
          'conductivityDone': false,
          'phDoneAt': null,
          'conductivityDoneAt': null,
        });
      }

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

  Future<void> _confirmActionWithWarning(
    Map<String, dynamic> user, {
    required bool isRemove,
  }) async {
    if (_isCalibrationCompleted(user)) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Warning'),
          content: const Text(
            'The calibration for this month is already done.\n\n'
            'Are you sure you want to continue with this request?',
            style: TextStyle(fontSize: 15),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isRemove ? 'Yes, Remove' : 'Yes, Reassign',
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    if (isRemove) {
      await _unassignTask(user);
    } else {
      await _assignTask(user);
    }
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
          if (!_isLoading) _buildStatsRow(),
          if (!_isLoading) _buildUserNameList(),
          const SizedBox(height: 8),
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
                      .map(
                        (m) => DropdownMenuItem<String>(
                          value: m,
                          child: Text(_formatMonthLabel(m)),
                        ),
                      )
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _StatChip(
              label: 'Assigned', value: _assignedCount, color: Colors.blue),
          _StatChip(
              label: 'Completed', value: _completedCount, color: Colors.green),
          _StatChip(
              label: 'Partial', value: _partialCount, color: Colors.orange),
        ],
      ),
    );
  }

  Widget _buildUserNameList() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _FilterTab(
                  label: 'All',
                  selected: _filterTab == 0,
                  onTap: () => _setFilterTab(0),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _FilterTab(
                  label: 'Assigned',
                  selected: _filterTab == 1,
                  onTap: () => _setFilterTab(1),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _FilterTab(
                  label: 'Done',
                  selected: _filterTab == 2,
                  onTap: () => _setFilterTab(2),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _FilterTab(
                  label: 'Partial',
                  selected: _filterTab == 3,
                  onTap: () => _setFilterTab(3),
                ),
              ),
            ],
          ),
          if (_filtered.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _filtered.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final user = _filtered[index];
                  return Chip(
                    label: Text(user['name'] as String),
                    visualDensity: VisualDensity.compact,
                  );
                },
              ),
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final bool assigned = user['assigned'] as bool;
    final bool phDone = user['phDone'] as bool;
    final bool condDone = user['condDone'] as bool;
    final bool isCompleted = _isCalibrationCompleted(user);

    final int? phDoneAt = user['phDoneAt'] as int?;
    final int? condDoneAt = user['condDoneAt'] as int?;

    final Color statusColor = !assigned
        ? Colors.grey
        : isCompleted
            ? Colors.green
            : (phDone || condDone)
                ? Colors.orange
                : Colors.blue;

    final String statusLabel = !assigned
        ? 'Not assigned'
        : isCompleted
            ? 'Completed - Locked'
            : (phDone && !condDone)
                ? 'pH Done - Conductivity Pending'
                : (!phDone && condDone)
                    ? 'Conductivity Done - pH Pending'
                    : 'Assigned';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                      style: TextStyle(color: statusColor, fontSize: 12)),
                  backgroundColor: statusColor.withOpacity(0.1)),
            ),
            if (assigned) ...[
              const Divider(height: 20),
              const Text('Calibration Progress',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 10),
              _buildSensorRow(Icons.science, 'pH Sensor', phDone, phDoneAt),
              const SizedBox(height: 8),
              _buildSensorRow(Icons.electrical_services, 'Conductivity Sensor',
                  condDone, condDoneAt),
            ],
            const SizedBox(height: 20),
            if (assigned)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _confirmActionWithWarning(user, isRemove: true),
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
                      onPressed: () =>
                          _confirmActionWithWarning(user, isRemove: false),
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

  Widget _buildSensorRow(
      IconData icon, String label, bool isDone, int? doneAt) {
    return Row(
      children: [
        Icon(icon, color: isDone ? Colors.green : Colors.grey, size: 22),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        Text(
          isDone ? 'Done ${_formatDate(doneAt)}' : 'Not Done',
          style: TextStyle(
              color: isDone ? Colors.green : Colors.red,
              fontWeight: isDone ? FontWeight.w500 : FontWeight.normal),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });

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
          Text(
            value.toString(),
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  const _FilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

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
