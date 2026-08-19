import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

// ─── Model ───────────────────────────────────────────────────────────────────

class CalibrationStep {
  final String id;
  final String title;
  final String description;
  final String? imageUrl;
  final String? imageAsset;
  final String firebaseCommand;
  final bool hasTimer;
  final Duration timerDuration;
  final IconData icon;

  CalibrationStep({
    required this.id,
    required this.title,
    required this.description,
    this.imageUrl,
    this.imageAsset,
    required this.firebaseCommand,
    this.hasTimer = false,
    this.timerDuration = Duration.zero,
    required this.icon,
  });
}

class CommandLog {
  final String command;
  final DateTime sentAt;
  final String stepTitle;
  final bool success;

  CommandLog({
    required this.command,
    required this.sentAt,
    required this.stepTitle,
    required this.success,
  });
}

// ─── Entry widget (mirrors the old phclibrationStepes) ───────────────────────

class PhCalibrationSteps extends StatelessWidget {
  final VoidCallback? onSkip;
  final VoidCallback onToggleCheck;

  const PhCalibrationSteps({
    super.key,
    this.onSkip,
    required this.onToggleCheck,
  });

  @override
  Widget build(BuildContext context) {
    final steps = [
      CalibrationStep(
        id: 'step_1',
        title: 'Rinse the Probe',
        description:
            'Rinse the pH probe thoroughly with distilled water to remove any contaminants.',
        imageUrl: 'https://i.ytimg.com/vi/hbDbr6Boy70/maxresdefault.jpg',
        firebaseCommand: 'ENTERPH',
        icon: Icons.water_drop_outlined,
      ),
      CalibrationStep(
        id: 'step_2',
        title: 'Submerge in Buffer',
        description:
            'Make sure the electrode is completely submerged in the buffer 4 or 7 solution.',
        imageAsset: 'assets/images/phc.webp',
        firebaseCommand: 'CALPH',
        icon: Icons.science_outlined,
      ),
      CalibrationStep(
        id: 'step_3',
        title: 'Wait for Stabilisation',
        description: 'Wait for 1–2 minutes until the reading stabilises.',
        firebaseCommand: 'CALPH',
        hasTimer: true,
        timerDuration: const Duration(seconds: 60),
        icon: Icons.timer_outlined,
      ),
      CalibrationStep(
        id: 'step_4',
        title: 'Finalise Calibration',
        description: 'Confirm the reading and exit calibration mode.',
        imageUrl:
            'https://static.vecteezy.com/system/resources/previews/012/916/688/original/green-check-mark-buttons-in-3d-realistic-style-checkmark-signs-illustration-png.png',
        firebaseCommand: 'EXITPH',
        icon: Icons.check_circle_outline,
      ),
    ];

    return PhCalibrationTodoList(
      steps: steps,
      onSkip: onSkip,
      onToggleCheck: onToggleCheck,
    );
  }
}

// ─── Main Todo-list widget ────────────────────────────────────────────────────

class PhCalibrationTodoList extends StatefulWidget {
  final List<CalibrationStep> steps;
  final VoidCallback? onSkip;
  final VoidCallback onToggleCheck;

  const PhCalibrationTodoList({
    super.key,
    required this.steps,
    this.onSkip,
    required this.onToggleCheck,
  });

  @override
  State<PhCalibrationTodoList> createState() => _PhCalibrationTodoListState();
}

class _PhCalibrationTodoListState extends State<PhCalibrationTodoList>
    with SingleTickerProviderStateMixin {
  // Track which steps are completed with timestamps
  final Map<String, DateTime> _completedSteps = {};

  // Active timer state (for step_3)
  Timer? _timer;
  int _remainingSeconds = 60;
  bool _timerRunning = false;
  bool _timerCompleted = false;

  // Command history log
  final List<CommandLog> _commandLog = [];

  // Firebase
  final DatabaseReference _commandRef =
      FirebaseDatabase.instance.ref('command');

  // Show/hide log panel
  bool _showLog = false;

  // Animation controller for log panel
  late AnimationController _logAnimController;
  late Animation<double> _logAnim;

  @override
  void initState() {
    super.initState();
    _logAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _logAnim = CurvedAnimation(
      parent: _logAnimController,
      curve: Curves.easeInOutCubic,
    );
    // Auto-send the first command on open
    _sendCommand(widget.steps.first);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _logAnimController.dispose();
    super.dispose();
  }

  // ── Firebase ──────────────────────────────────────────────────────────────

  Future<void> _sendCommand(CalibrationStep step) async {
    bool success = false;
    try {
      await _commandRef.set(step.firebaseCommand);
      success = true;
      debugPrint('✅ Firebase command sent: ${step.firebaseCommand}');
    } catch (e) {
      debugPrint('❌ Firebase error: $e');
    }

    // Save to local log regardless
    setState(() {
      _commandLog.insert(
        0,
        CommandLog(
          command: step.firebaseCommand,
          sentAt: DateTime.now(),
          stepTitle: step.title,
          success: success,
        ),
      );
    });
  }

  // ── Timer (step 3) ────────────────────────────────────────────────────────

  void _startTimer(CalibrationStep step) {
    if (_timerRunning || _timerCompleted) return;

    setState(() {
      _remainingSeconds = step.timerDuration.inSeconds;
      _timerRunning = true;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_remainingSeconds > 0) {
          _remainingSeconds--;
        } else {
          _timerRunning = false;
          _timerCompleted = true;
          t.cancel();
          _sendCommand(step); // CALPH after timer
        }
      });
    });
  }

  // ── Step completion logic ─────────────────────────────────────────────────

  bool _isStepUnlocked(int index) {
    if (index == 0) return true;
    return _completedSteps.containsKey(widget.steps[index - 1].id);
  }

  bool _isStepCompleted(String id) => _completedSteps.containsKey(id);

  void _handleStepTap(int index) {
    final step = widget.steps[index];

    if (!_isStepUnlocked(index)) {
      _showLockedSnack();
      return;
    }

    if (_isStepCompleted(step.id)) return; // Already done

    // Timer step: must wait for timer
    if (step.hasTimer) {
      if (!_timerCompleted) {
        if (!_timerRunning) _startTimer(step);
        _showTimerSnack();
        return;
      }
    }

    // Mark complete + send command
    _sendCommand(step);
    setState(() => _completedSteps[step.id] = DateTime.now());

    // Last step → finish
    if (index == widget.steps.length - 1) {
      Future.delayed(const Duration(milliseconds: 400), _finishCalibration);
    }
  }

  Future<void> _finishCalibration() async {
    widget.onToggleCheck();
    try {
      final snap = await _commandRef.get();
      if (snap.exists && snap.value == 'EXITPH') {
        await _commandRef.remove();
        debugPrint('✅ Removed EXITPH command from Firebase');
      }
    } catch (e) {
      debugPrint('Error removing EXITPH command: $e');
    }

    if (mounted) Navigator.pop(context);
  }

  void _showLockedSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Complete the previous step first.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _showTimerSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_timerRunning
            ? 'Wait $_remainingSeconds seconds for stabilisation…'
            : 'Timer started! Wait until it finishes.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final allDone = _completedSteps.length == widget.steps.length;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          Column(
            children: [
              _buildProgressHeader(allDone),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  itemCount: widget.steps.length,
                  itemBuilder: (ctx, i) => _buildStepCard(i),
                ),
              ),
            ],
          ),
          // Log panel slide-up
          if (_showLog) _buildLogPanel(),
          // Finish button
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomBar(allDone),
          ),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF161B22),
      elevation: 0,
      title: const Text(
        'pH Calibration',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 18,
          letterSpacing: 0.5,
        ),
      ),
      actions: [
        // Command log toggle
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: Icon(
                  Icons.receipt_long_outlined,
                  color: _showLog ? const Color(0xFF4ECDC4) : Colors.white60,
                ),
                tooltip: 'Command log',
                onPressed: () {
                  setState(() => _showLog = !_showLog);
                  _showLog
                      ? _logAnimController.forward()
                      : _logAnimController.reverse();
                },
              ),
              if (_commandLog.isNotEmpty)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4ECDC4),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (widget.onSkip != null)
          TextButton(
            onPressed: widget.onSkip,
            child: const Text('Skip',
                style: TextStyle(color: Colors.white38, fontSize: 14)),
          ),
      ],
    );
  }

  Widget _buildProgressHeader(bool allDone) {
    final done = _completedSteps.length;
    final total = widget.steps.length;
    final progress = total == 0 ? 0.0 : done / total;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      color: const Color(0xFF161B22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                allDone ? '✓ All steps complete' : '$done of $total steps done',
                style: TextStyle(
                  color: allDone ? const Color(0xFF4ECDC4) : Colors.white60,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                  color: Color(0xFF4ECDC4),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (_, val, __) => LinearProgressIndicator(
                value: val,
                minHeight: 6,
                backgroundColor: const Color(0xFF30363D),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFF4ECDC4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepCard(int index) {
    final step = widget.steps[index];
    final completed = _isStepCompleted(step.id);
    final unlocked = _isStepUnlocked(index);
    final isTimerStep = step.hasTimer;
    final isActive = unlocked && !completed;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: completed
            ? const Color(0xFF0D2B29)
            : unlocked
                ? const Color(0xFF161B22)
                : const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: completed
              ? const Color(0xFF4ECDC4).withOpacity(0.5)
              : isActive
                  ? const Color(0xFF4ECDC4).withOpacity(0.25)
                  : const Color(0xFF30363D),
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _handleStepTap(index),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Step indicator
              _buildStepIndicator(index, completed, unlocked, isTimerStep),
              const SizedBox(width: 14),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          step.title,
                          style: TextStyle(
                            color: completed
                                ? const Color(0xFF4ECDC4)
                                : unlocked
                                    ? Colors.white
                                    : Colors.white38,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            decoration: completed
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                            decorationColor:
                                const Color(0xFF4ECDC4).withOpacity(0.6),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Command badge
                        _buildCommandBadge(step.firebaseCommand, completed),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      step.description,
                      style: TextStyle(
                        color: unlocked ? Colors.white60 : Colors.white24,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    // Timer widget if applicable
                    if (isTimerStep && unlocked) ...[
                      const SizedBox(height: 12),
                      _buildInlineTimer(step),
                    ],
                    // Completion timestamp
                    if (completed) ...[
                      const SizedBox(height: 8),
                      _buildCompletionBadge(step.id),
                    ],
                  ],
                ),
              ),
              // Right check / chevron
              const SizedBox(width: 8),
              _buildRightIcon(completed, unlocked),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator(
      int index, bool completed, bool unlocked, bool hasTimer) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: completed
            ? const Color(0xFF4ECDC4)
            : unlocked
                ? const Color(0xFF21262D)
                : const Color(0xFF161B22),
        border: Border.all(
          color: completed
              ? const Color(0xFF4ECDC4)
              : unlocked
                  ? const Color(0xFF4ECDC4).withOpacity(0.4)
                  : const Color(0xFF30363D),
          width: 1.5,
        ),
      ),
      child: Center(
        child: completed
            ? const Icon(Icons.check, color: Color(0xFF0D2B29), size: 22)
            : Icon(
                widget.steps[index].icon,
                color: unlocked ? const Color(0xFF4ECDC4) : Colors.white24,
                size: 20,
              ),
      ),
    );
  }

  Widget _buildCommandBadge(String command, bool completed) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: completed
            ? const Color(0xFF4ECDC4).withOpacity(0.15)
            : const Color(0xFF30363D),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        command,
        style: TextStyle(
          color: completed ? const Color(0xFF4ECDC4) : Colors.white38,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  Widget _buildInlineTimer(CalibrationStep step) {
    final pct = (_timerCompleted || step.timerDuration.inSeconds == 0)
        ? 1.0
        : _timerRunning
            ? 1.0 - (_remainingSeconds / step.timerDuration.inSeconds)
            : 0.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _timerCompleted
                    ? Icons.check_circle
                    : _timerRunning
                        ? Icons.timer
                        : Icons.timer_outlined,
                color:
                    _timerCompleted ? const Color(0xFF4ECDC4) : Colors.white54,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                _timerCompleted
                    ? 'Stabilised!'
                    : _timerRunning
                        ? '$_remainingSeconds s remaining…'
                        : 'Tap to start ${step.timerDuration.inSeconds}s timer',
                style: TextStyle(
                  color: _timerCompleted
                      ? const Color(0xFF4ECDC4)
                      : Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: pct),
              duration: const Duration(milliseconds: 600),
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                minHeight: 4,
                backgroundColor: const Color(0xFF30363D),
                valueColor: AlwaysStoppedAnimation<Color>(
                  _timerCompleted
                      ? const Color(0xFF4ECDC4)
                      : const Color(0xFF58A6FF),
                ),
              ),
            ),
          ),
          if (!_timerRunning && !_timerCompleted) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 32,
              child: ElevatedButton.icon(
                onPressed: () => _startTimer(step),
                icon: const Icon(Icons.play_arrow, size: 16),
                label:
                    const Text('Start Timer', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF21262D),
                  foregroundColor: const Color(0xFF4ECDC4),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompletionBadge(String stepId) {
    final completedAt = _completedSteps[stepId];
    if (completedAt == null) return const SizedBox.shrink();

    final timeStr =
        '${completedAt.hour.toString().padLeft(2, '0')}:${completedAt.minute.toString().padLeft(2, '0')}:${completedAt.second.toString().padLeft(2, '0')}';

    return Row(
      children: [
        const Icon(Icons.check_circle, color: Color(0xFF4ECDC4), size: 13),
        const SizedBox(width: 4),
        Text(
          'Completed at $timeStr',
          style: const TextStyle(
            color: Color(0xFF4ECDC4),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildRightIcon(bool completed, bool unlocked) {
    if (completed) {
      return const Icon(Icons.check_circle, color: Color(0xFF4ECDC4), size: 22);
    }
    if (!unlocked) {
      return const Icon(Icons.lock_outline, color: Colors.white24, size: 18);
    }
    return const Icon(Icons.chevron_right, color: Colors.white38, size: 22);
  }

  Widget _buildBottomBar(bool allDone) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF30363D))),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: allDone ? _finishCalibration : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4ECDC4),
            disabledBackgroundColor: const Color(0xFF21262D),
            foregroundColor: const Color(0xFF0D2B29),
            disabledForegroundColor: Colors.white38,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(allDone ? Icons.done_all : Icons.hourglass_empty, size: 20),
              const SizedBox(width: 8),
              Text(
                allDone ? 'Finish Calibration' : 'Complete all steps to finish',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Command Log Panel ─────────────────────────────────────────────────────

  Widget _buildLogPanel() {
    return Positioned(
      bottom: 88,
      left: 16,
      right: 16,
      child: FadeTransition(
        opacity: _logAnim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.1),
            end: Offset.zero,
          ).animate(_logAnim),
          child: Material(
            color: const Color(0xFF161B22),
            borderRadius: BorderRadius.circular(16),
            elevation: 8,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF30363D)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.receipt_long,
                            color: Color(0xFF4ECDC4), size: 16),
                        const SizedBox(width: 8),
                        const Text(
                          'Command Log',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_commandLog.length} sent',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Color(0xFF30363D), height: 1),
                  // Log entries
                  Flexible(
                    child: _commandLog.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'No commands sent yet.',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 13),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: _commandLog.length,
                            separatorBuilder: (_, __) => const Divider(
                                color: Color(0xFF21262D), height: 1),
                            itemBuilder: (_, i) =>
                                _buildLogEntry(_commandLog[i]),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogEntry(CommandLog log) {
    final t = log.sentAt;
    final timeStr =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          // Status dot
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: log.success
                  ? const Color(0xFF4ECDC4)
                  : const Color(0xFFFF6B6B),
            ),
          ),
          const SizedBox(width: 10),
          // Command
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              log.command,
              style: const TextStyle(
                color: Color(0xFF58A6FF),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Step name
          Expanded(
            child: Text(
              log.stepTitle,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
          // Time
          Text(
            timeStr,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
