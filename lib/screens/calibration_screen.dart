import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'ec.dart';
import 'ph.dart';

class CalibrationScreen extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const CalibrationScreen({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  bool _isLoading = true;
  bool _isAssigned = false;
  bool _isSubmitting = false;

  bool _phDone = false;
  bool _condDone = false;
  String _phDoneByName = '';
  String _condDoneByName = '';
  int? _phDoneAt;
  int? _condDoneAt;

  String _displayName = '';
  StreamSubscription<DatabaseEvent>? _sharedSubscription;

  String get _currentMonth {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  String get _uid => FirebaseAuth.instance.currentUser!.uid;

  bool get _allDone => _phDone && _condDone;

  @override
  void initState() {
    super.initState();
    _initUser();
  }

  @override
  void dispose() {
    _sharedSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      return;
    }

    _displayName = user.displayName?.trim().isNotEmpty == true
        ? user.displayName!.trim()
        : user.email?.split('@').first ?? 'User';

    await _checkAssignment();
    _listenToSharedStatus();
  }

  Future<void> _checkAssignment() async {
    try {
      final snap = await FirebaseDatabase.instance
          .ref('calibrations/$_uid/$_currentMonth')
          .get();

      final assigned = snap.exists &&
          snap.value is Map &&
          ((snap.value as Map)['assignedBy']?.toString().isNotEmpty == true);

      if (!mounted) return;
      setState(() {
        _isAssigned = assigned;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Assignment check error: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _listenToSharedStatus() {
    _sharedSubscription?.cancel();
    _sharedSubscription = FirebaseDatabase.instance
        .ref('calibrationShared/$_currentMonth')
        .onValue
        .listen((event) {
      if (!mounted) return;

      if (event.snapshot.exists && event.snapshot.value is Map) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        setState(() {
          _phDone = data['phDone'] == true;
          _condDone = data['conductivityDone'] == true;
          _phDoneByName = data['phDoneByName']?.toString() ?? '';
          _condDoneByName = data['conductivityDoneByName']?.toString() ?? '';
          _phDoneAt = data['phDoneAt'] is int ? data['phDoneAt'] as int : null;
          _condDoneAt = data['conductivityDoneAt'] is int
              ? data['conductivityDoneAt'] as int
              : null;
        });
      } else {
        setState(() {
          _phDone = false;
          _condDone = false;
          _phDoneByName = '';
          _condDoneByName = '';
          _phDoneAt = null;
          _condDoneAt = null;
        });
      }
    });
  }

  Future<void> _markTaskDone(String taskKey) async {
    setState(() => _isSubmitting = true);
    try {
      final byNameKey = '${taskKey}ByName';
      final atKey = '${taskKey}At';

      final sharedKey =
          taskKey == 'conductivityDone' ? 'conductivityDone' : 'phDone';
      final sharedByNameKey = '${sharedKey}ByName';
      final sharedAtKey = '${sharedKey}At';

      await FirebaseDatabase.instance
          .ref('calibrationShared/$_currentMonth')
          .update({
        sharedKey: true,
        sharedByNameKey: _displayName,
        sharedAtKey: ServerValue.timestamp,
      });

      await FirebaseDatabase.instance
          .ref('calibrations/$_uid/$_currentMonth')
          .update({
        taskKey: true,
        atKey: ServerValue.timestamp,
        byNameKey: _displayName,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Task marked as done!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Mark done error: $e');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _openPhCalibration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhCalibrationSteps(
          onToggleCheck: () => _markTaskDone('phDone'),
        ),
      ),
    );
  }

  Future<void> _openConductivityCalibration() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EcCalibrationSteps(
          onToggleCheck: () => _markTaskDone('conductivityDone'),
        ),
      ),
    );
  }

  String _formatDate(int? ms) {
    if (ms == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibration'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildHeader(theme),
                const SizedBox(height: 16),
                if (!_isAssigned)
                  _buildNotAssignedCard()
                else ...[
                  _buildTaskCard(
                    context,
                    title: 'pH Calibration',
                    icon: Icons.science,
                    isDone: _phDone,
                    doneByName: _phDoneByName,
                    doneAt: _phDoneAt,
                    onTap:
                        (_phDone || _isSubmitting) ? null : _openPhCalibration,
                  ),
                  const SizedBox(height: 12),
                  _buildTaskCard(
                    context,
                    title: 'Conductivity Calibration',
                    icon: Icons.electrical_services,
                    isDone: _condDone,
                    doneByName: _condDoneByName,
                    doneAt: _condDoneAt,
                    onTap: (_condDone || _isSubmitting)
                        ? null
                        : _openConductivityCalibration,
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _allDone
            ? Colors.green.shade50
            : theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _allDone
              ? Colors.green.shade200
              : theme.colorScheme.primary.withOpacity(0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Monthly Calibration',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            !_isAssigned
                ? 'No task assigned to you this month.'
                : _allDone
                    ? 'All calibration tasks completed for this month.'
                    : 'Complete both calibration tasks to finish the monthly checklist.',
          ),
        ],
      ),
    );
  }

  Widget _buildNotAssignedCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              'No task assigned',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 6),
            Text(
              'Your admin has not assigned a calibration task to you this month.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(
    BuildContext context, {
    required String title,
    required IconData icon,
    required bool isDone,
    required String doneByName,
    required int? doneAt,
    required VoidCallback? onTap,
  }) {
    final color = isDone ? Colors.green : Theme.of(context).colorScheme.primary;
    final doneByMe = isDone && doneByName == _displayName;

    final subtitle = isDone
        ? doneByMe
            ? 'Completed by you • ${_formatDate(doneAt)}'
            : 'Completed by $doneByName • ${_formatDate(doneAt)}'
        : 'Tap to start calibration steps';

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDone ? Colors.green.shade200 : Colors.grey.shade200,
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.12),
          child: Icon(icon, color: color),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        trailing: isDone
            ? Icon(
                doneByMe ? Icons.check_circle : Icons.lock,
                color: Colors.green,
              )
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
