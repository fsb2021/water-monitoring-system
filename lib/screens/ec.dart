import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

// ─── Models ──────────────────────────────────────────────────────────────────

enum StepStatus { locked, pending, inProgress, skipped, completed }

enum StepType { normal, yesNo, timer }

class EcCalibrationStepModel {
  final String id;
  final String title;
  final String description;
  final String? imageAsset;
  final String? imageUrl;
  final String? firebaseCommand;
  final StepType type;
  final Duration? timerDuration;
  final IconData icon;
  final bool conditionalStep; // can be skipped by Yes/No

  const EcCalibrationStepModel({
    required this.id,
    required this.title,
    required this.description,
    this.imageAsset,
    this.imageUrl,
    this.firebaseCommand,
    this.type = StepType.normal,
    this.timerDuration,
    required this.icon,
    this.conditionalStep = false,
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

// ─── Entry point ─────────────────────────────────────────────────────────────

class EcCalibrationSteps extends StatelessWidget {
  final VoidCallback? onSkip;
  final VoidCallback onToggleCheck;

  const EcCalibrationSteps({
    super.key,
    this.onSkip,
    required this.onToggleCheck,
  });

  static final List<EcCalibrationStepModel> steps = [
    EcCalibrationStepModel(
      id: 'sensor_check',
      title: 'Sensor Check',
      description: 'Is the sensor clear and clean?',
      imageAsset: 'assets/images/ecd.png',
      type: StepType.yesNo,
      icon: Icons.search_outlined,
    ),
    EcCalibrationStepModel(
      id: 'hcl_soak',
      title: 'HCl Soak',
      description:
          'Put the sensor in the 10% HCl solution and wait 30 minutes.',
      imageAsset: 'assets/images/timer.png',

      // No STM32 command during cleaning.
      type: StepType.timer,
      timerDuration: const Duration(minutes: 30),
      icon: Icons.science_outlined,
      conditionalStep: true,
    ),
    EcCalibrationStepModel(
      id: 'cal_point_1',
      title: 'Calibration Point 1',
      description:
          'Submerge the electrode completely in the 12.88 mS/cm solution.',
      imageAsset: 'assets/images/12.8.png',
      icon: Icons.water_outlined,
    ),
    EcCalibrationStepModel(
      id: 'stabilise_1',
      title: 'Stabilisation #1',
      description: 'Wait until the reading stabilises (60 s).',

      // Saved by STM32 as calibration point 1.
      firebaseCommand: 'CALEC1:12.88',

      type: StepType.timer,
      timerDuration: const Duration(seconds: 60),
      icon: Icons.timer_outlined,
    ),
    EcCalibrationStepModel(
      id: 'rinse',
      title: 'Rinse the Sensor',
      description:
          'Rinse the electrode thoroughly with distilled water before the second calibration point.',
      imageAsset: 'assets/images/rinse.png',
      icon: Icons.water_drop_outlined,
    ),
    EcCalibrationStepModel(
      id: 'cal_point_2',
      title: 'Calibration Point 2',
      description:
          'Submerge the electrode completely in the 1413 µS/cm solution.',
      imageAsset: 'assets/images/1413 Scm.jpg',
      icon: Icons.water_outlined,
    ),
    EcCalibrationStepModel(
      id: 'stabilise_2',
      title: 'Stabilisation #2',
      description: 'Wait until the reading stabilises (60 s).',

      // 1413 µS/cm = 1.413 mS/cm.
      firebaseCommand: 'CALEC2:1.413',

      type: StepType.timer,
      timerDuration: const Duration(seconds: 60),
      icon: Icons.timer_outlined,
    ),
    EcCalibrationStepModel(
      id: 'done',
      title: 'Calibration Complete',
      description: 'The EC sensor is fully calibrated and ready to use.',
      imageUrl:
          'https://static.vecteezy.com/system/resources/previews/012/916/688/original/green-check-mark-buttons-in-3d-realistic-style-checkmark-signs-illustration-png.png',

      // STM32 calculates slope and offset here.
      firebaseCommand: 'EXITEC',

      icon: Icons.check_circle_outline,
    ),
  ];

// ─── Main widget ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return EcCalibrationTodoList(
      steps: steps,
      onSkip: onSkip,
      onToggleCheck: onToggleCheck,
    );
  }
}

class EcCalibrationTodoList extends StatefulWidget {
  final List<EcCalibrationStepModel> steps;
  final VoidCallback? onSkip;
  final VoidCallback onToggleCheck;

  const EcCalibrationTodoList({
    super.key,
    required this.steps,
    this.onSkip,
    required this.onToggleCheck,
  });

  @override
  State<EcCalibrationTodoList> createState() => _EcCalibrationTodoListState();
}

class _EcCalibrationTodoListState extends State<EcCalibrationTodoList>
    with SingleTickerProviderStateMixin {
  // Status map: stepId → StepStatus
  late Map<String, StepStatus> _statusMap;

  // Active timer: stepId → remaining seconds
  final Map<String, int> _timerRemaining = {};
  final Map<String, bool> _timerRunning = {};
  final Map<String, Timer> _timers = {};

  // Command log
  final List<CommandLog> _commandLog = [];

  // Firebase
  final DatabaseReference _commandRef =
      FirebaseDatabase.instance.ref('command');

  // Log panel
  bool _showLog = false;
  late AnimationController _logAnimCtrl;
  late Animation<double> _logAnim;

  // Accent colour for EC = amber/teal combo
  static const Color kAccent = Color(0xFFFFB347);
  static const Color kBg = Color(0xFF0D1117);
  static const Color kSurface = Color(0xFF161B22);
  static const Color kBorder = Color(0xFF30363D);

  @override
  void initState() {
    super.initState();

    // Initialise all steps as locked; unlock first one
    _statusMap = {
      for (final s in widget.steps) s.id: StepStatus.locked,
    };
    _statusMap[widget.steps.first.id] = StepStatus.pending;

    // Pre-fill timer remaining for timer steps
    for (final s in widget.steps) {
      if (s.type == StepType.timer && s.timerDuration != null) {
        _timerRemaining[s.id] = s.timerDuration!.inSeconds;
        _timerRunning[s.id] = false;
      }
    }

    _logAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _logAnim =
        CurvedAnimation(parent: _logAnimCtrl, curve: Curves.easeInOutCubic);

    // Auto-send ENTEREC
    _sendRawCommand('ENTEREC', 'Initialise EC calibration');
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _logAnimCtrl.dispose();
    super.dispose();
  }

  // ── Firebase ───────────────────────────────────────────────────────────────

  Future<void> _sendRawCommand(String command, String label) async {
    bool success = false;
    try {
      await _commandRef.set(command);
      success = true;
      debugPrint('✅ Firebase: $command');
    } catch (e) {
      debugPrint('❌ Firebase error: $e');
    }
    setState(() {
      _commandLog.insert(
        0,
        CommandLog(
          command: command,
          sentAt: DateTime.now(),
          stepTitle: label,
          success: success,
        ),
      );
    });
  }

  Future<void> _sendStepCommand(EcCalibrationStepModel step) async {
    if (step.firebaseCommand != null) {
      await _sendRawCommand(step.firebaseCommand!, step.title);
    }
  }

  // ── Step state helpers ─────────────────────────────────────────────────────

  StepStatus _status(String id) => _statusMap[id] ?? StepStatus.locked;

  bool _isUnlocked(String id) {
    final s = _status(id);
    return s == StepStatus.pending ||
        s == StepStatus.inProgress ||
        s == StepStatus.skipped;
  }

  bool _isDone(String id) {
    final s = _status(id);
    return s == StepStatus.completed || s == StepStatus.skipped;
  }

  int _indexOf(String id) => widget.steps.indexWhere((s) => s.id == id);

  /// Mark step done and unlock the next one.
  void _completeStep(EcCalibrationStepModel step) {
    setState(() => _statusMap[step.id] = StepStatus.completed);
    _unlockNextAfter(step.id);
  }

  void _skipStep(EcCalibrationStepModel step) {
    setState(() => _statusMap[step.id] = StepStatus.skipped);
    _unlockNextAfter(step.id);
  }

  void _unlockNextAfter(String id) {
    final idx = _indexOf(id);
    if (idx < widget.steps.length - 1) {
      final next = widget.steps[idx + 1];
      if (_status(next.id) == StepStatus.locked) {
        setState(() => _statusMap[next.id] = StepStatus.pending);
      }
    }
  }

  // ── Timer logic ────────────────────────────────────────────────────────────

  void _startTimer(EcCalibrationStepModel step) {
    if (_timerRunning[step.id] == true) return;

    setState(() {
      _timerRunning[step.id] = true;
      _statusMap[step.id] = StepStatus.inProgress;
    });

    _timers[step.id] = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        final rem = (_timerRemaining[step.id] ?? 1) - 1;
        _timerRemaining[step.id] = rem;
        if (rem <= 0) {
          _timerRunning[step.id] = false;
          t.cancel();
          _timers.remove(step.id);
          _sendStepCommand(step); // CALEC
          _completeStep(step);
        }
      });
    });
  }

  // ── Completion counting ────────────────────────────────────────────────────

  int get _doneCount => _statusMap.values
      .where((s) => s == StepStatus.completed || s == StepStatus.skipped)
      .length;

  bool get _allDone => _doneCount == widget.steps.length;

  // ── Finish ─────────────────────────────────────────────────────────────────

  Future<void> _finishCalibration() async {
    widget.onToggleCheck();
    // Remove EXITEC command from Firebase to avoid leaving stale commands
    try {
      final snap = await _commandRef.get();
      if (snap.exists && snap.value == 'EXITEC') {
        await _commandRef.remove();
        debugPrint('✅ Removed EXITEC command from Firebase');
      }
    } catch (e) {
      debugPrint('Error removing EXITEC command: $e');
    }

    if (mounted) Navigator.pop(context);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF111827),
                    Color(0xFF0D1117),
                    Color(0xFF0A0F14),
                  ],
                ),
              ),
            ),
          ),
          Column(
            children: [
              _buildHeroBanner(),
              _buildProgressHeader(),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  itemCount: widget.steps.length,
                  itemBuilder: (_, i) => _buildCard(i),
                ),
              ),
            ],
          ),
          if (_showLog) _buildLogPanel(),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildBottomBar(),
          ),
        ],
      ),
    );
  }

  // ── AppBar ─────────────────────────────────────────────────────────────────

  AppBar _buildAppBar() => AppBar(
        backgroundColor: kSurface,
        elevation: 0,
        title: const Text(
          'EC Calibration',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 18,
            letterSpacing: 0.5,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.receipt_long_outlined,
                    color: _showLog ? kAccent : Colors.white60,
                  ),
                  tooltip: 'Command log',
                  onPressed: () {
                    setState(() => _showLog = !_showLog);
                    _showLog ? _logAnimCtrl.forward() : _logAnimCtrl.reverse();
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
                        color: kAccent,
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

  // ── Progress header ────────────────────────────────────────────────────────

  Widget _buildHeroBanner() {
    final done = _doneCount;
    final total = widget.steps.length;
    final percent = total == 0 ? 0 : ((done / total) * 100).round();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1F2A37), Color(0xFF141A24)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kAccent.withOpacity(0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFFFFD07A), Color(0xFFFFB347)],
              ),
              boxShadow: [
                BoxShadow(
                  color: kAccent.withOpacity(0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(Icons.science_outlined,
                color: Color(0xFF1A1A00), size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'EC Calibration',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Follow the guided flow to clean, calibrate, and finish the sensor.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.68),
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildPill('$percent% complete', kAccent),
                    _buildPill('$done/$total steps', const Color(0xFF58A6FF)),
                    _buildPill('Live command log', const Color(0xFF56C596)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressHeader() {
    final done = _doneCount;
    final total = widget.steps.length;
    final progress = total == 0 ? 0.0 : done / total;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _allDone
                    ? '✓ All steps complete'
                    : '$done of $total steps done',
                style: TextStyle(
                  color: _allDone ? kAccent : Colors.white60,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(
                  color: kAccent,
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
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: kBorder,
                valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step card ──────────────────────────────────────────────────────────────

  Widget _buildCard(int index) {
    final step = widget.steps[index];
    final status = _status(step.id);
    final unlocked = _isUnlocked(step.id);
    final done = _isDone(step.id);
    final skipped = status == StepStatus.skipped;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: done
            ? skipped
                ? const Color(0xFF1A1A2E)
                : const Color(0xFF1A2A1A)
            : unlocked
                ? kSurface
                : kBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: done
              ? skipped
                  ? Colors.white24
                  : kAccent.withOpacity(0.45)
              : unlocked
                  ? kAccent.withOpacity(0.22)
                  : kBorder,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: (done ||
                !unlocked ||
                step.type == StepType.timer ||
                step.type == StepType.yesNo)
            ? null
            : () => _handleNormalTap(step),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildIndicator(step, status, unlocked),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStepMedia(step),
                    if (step.imageAsset != null || step.imageUrl != null)
                      const SizedBox(height: 12),
                    // Title row
                    Row(children: [
                      Expanded(
                        child: Text(
                          step.title,
                          style: TextStyle(
                            color: done
                                ? kAccent
                                : unlocked
                                    ? Colors.white
                                    : Colors.white38,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            decoration: skipped
                                ? TextDecoration.lineThrough
                                : done
                                    ? TextDecoration.lineThrough
                                    : TextDecoration.none,
                            decorationColor: kAccent.withOpacity(0.5),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (step.conditionalStep)
                        _buildPill('OPTIONAL', Colors.blueGrey),
                      if (step.firebaseCommand != null)
                        _buildCommandBadge(step.firebaseCommand!, done),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      step.description,
                      style: TextStyle(
                        color: unlocked ? Colors.white60 : Colors.white24,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    // Type-specific extras
                    if (unlocked && !done) ...[
                      const SizedBox(height: 12),
                      if (step.type == StepType.yesNo) _buildYesNoButtons(step),
                      if (step.type == StepType.timer) _buildInlineTimer(step),
                    ],
                    // Completion row
                    if (done) ...[
                      const SizedBox(height: 8),
                      _buildDoneBadge(step, skipped),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildRightIcon(status, unlocked),
            ],
          ),
        ),
      ),
    );
  }

  // ── Card sub-widgets ───────────────────────────────────────────────────────

  Widget _buildIndicator(
      EcCalibrationStepModel step, StepStatus status, bool unlocked) {
    final done = status == StepStatus.completed;
    final skipped = status == StepStatus.skipped;
    final inProg = status == StepStatus.inProgress;

    Color bg = done || skipped
        ? kAccent
        : unlocked
            ? const Color(0xFF21262D)
            : kBg;
    Color border = done || skipped
        ? kAccent
        : inProg
            ? kAccent.withOpacity(0.6)
            : unlocked
                ? kAccent.withOpacity(0.35)
                : kBorder;

    Widget icon = done
        ? const Icon(Icons.check, color: Color(0xFF1A2A1A), size: 22)
        : skipped
            ? const Icon(Icons.skip_next, color: Color(0xFF1A1A2E), size: 22)
            : inProg
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(kAccent),
                    ),
                  )
                : Icon(step.icon,
                    color: unlocked ? kAccent : Colors.white24, size: 20);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bg,
        border: Border.all(color: border, width: 1.5),
      ),
      child: Center(child: icon),
    );
  }

  Widget _buildPill(String label, Color color) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.38)),
        ),
        child: Text(label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            )),
      );

  Widget _buildCommandBadge(String cmd, bool done) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: done ? kAccent.withOpacity(0.15) : const Color(0xFF30363D),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          cmd,
          style: TextStyle(
            color: done ? kAccent : Colors.white38,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            fontFamily: 'monospace',
          ),
        ),
      );

  Widget _buildRightIcon(StepStatus status, bool unlocked) {
    if (status == StepStatus.completed) {
      return Icon(Icons.check_circle, color: kAccent, size: 22);
    }
    if (status == StepStatus.skipped) {
      return const Icon(Icons.skip_next, color: Colors.white38, size: 22);
    }
    if (!unlocked) {
      return const Icon(Icons.lock_outline, color: Colors.white24, size: 18);
    }
    return const Icon(Icons.chevron_right, color: Colors.white38, size: 22);
  }

  Widget _buildDoneBadge(EcCalibrationStepModel step, bool skipped) {
    // Find matching log
    final log = _commandLog.cast<CommandLog?>().firstWhere(
          (l) => l?.stepTitle == step.title,
          orElse: () => null,
        );

    final timeStr = log != null
        ? '${log.sentAt.hour.toString().padLeft(2, '0')}:'
            '${log.sentAt.minute.toString().padLeft(2, '0')}:'
            '${log.sentAt.second.toString().padLeft(2, '0')}'
        : 'done';

    return Row(children: [
      Icon(
        skipped ? Icons.skip_next : Icons.check_circle,
        color: kAccent,
        size: 13,
      ),
      const SizedBox(width: 4),
      Text(
        skipped ? 'Skipped (sensor clean)' : 'Completed at $timeStr',
        style: TextStyle(
          color: kAccent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ]);
  }

  // ── Yes / No buttons ───────────────────────────────────────────────────────

  Widget _buildYesNoButtons(EcCalibrationStepModel step) {
    return Row(
      children: [
        Expanded(
          child: _actionButton(
            label: 'No – dirty',
            icon: Icons.close,
            color: const Color(0xFFFF6B6B),
            onPressed: () {
              // Mark sensor check complete, HCl step stays pending (unlocked)
              _completeStep(step);
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _actionButton(
            label: 'Yes – clean',
            icon: Icons.check,
            color: const Color(0xFF56C596),
            onPressed: () {
              // Complete sensor check then skip HCl soak
              _completeStep(step);
              final hclStep =
                  widget.steps.firstWhere((s) => s.id == 'hcl_soak');
              Future.microtask(() {
                setState(() => _statusMap['hcl_soak'] = StepStatus.pending);
                _skipStep(hclStep);
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) =>
      ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color.withOpacity(0.18),
          foregroundColor: color,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          side: BorderSide(color: color.withOpacity(0.4)),
        ),
      );

  Widget _buildStepMedia(EcCalibrationStepModel step) {
    final hasMedia = step.imageAsset != null || step.imageUrl != null;
    if (!hasMedia) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 148,
        width: double.infinity,
        decoration: BoxDecoration(
          color: kBg,
          border: Border.all(color: kBorder),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (step.imageAsset != null)
              Image.asset(
                step.imageAsset!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildMediaFallback(step),
              )
            else if (step.imageUrl != null)
              Image.network(
                step.imageUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildMediaFallback(step),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.22),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaFallback(EcCalibrationStepModel step) {
    return Container(
      color: const Color(0xFF1B2430),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kAccent.withOpacity(0.18),
            ),
            child: Icon(step.icon, color: kAccent, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              step.title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Inline timer ───────────────────────────────────────────────────────────

  Widget _buildInlineTimer(EcCalibrationStepModel step) {
    final totalSec = step.timerDuration!.inSeconds;
    final remaining = _timerRemaining[step.id] ?? totalSec;
    final running = _timerRunning[step.id] ?? false;
    final isDone = _isDone(step.id);
    final pct = isDone
        ? 1.0
        : running
            ? (totalSec - remaining) / totalSec
            : 0.0;

    // Format mm:ss for long timers, ss for short
    final isLong = totalSec >= 60;
    final timeText = isLong
        ? '${(remaining ~/ 60).toString().padLeft(2, '0')}:'
            '${(remaining % 60).toString().padLeft(2, '0')}'
        : '$remaining s';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
              isDone
                  ? Icons.check_circle
                  : running
                      ? Icons.timer
                      : Icons.timer_outlined,
              color: isDone ? kAccent : Colors.white54,
              size: 16,
            ),
            const SizedBox(width: 8),
            Text(
              isDone
                  ? 'Timer complete!'
                  : running
                      ? '$timeText remaining…'
                      : 'Tap to start — $timeText',
              style: TextStyle(
                color: isDone ? kAccent : Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamily: isLong ? 'monospace' : null,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: pct),
              duration: const Duration(milliseconds: 600),
              builder: (_, v, __) => LinearProgressIndicator(
                value: v,
                minHeight: 4,
                backgroundColor: kBorder,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isDone ? kAccent : const Color(0xFF58A6FF),
                ),
              ),
            ),
          ),
          if (!running && !isDone) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 34,
              child: ElevatedButton.icon(
                onPressed: () => _startTimer(step),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(
                  'Start ${isLong ? "${step.timerDuration!.inMinutes} min" : "${totalSec}s"} Timer',
                  style: const TextStyle(fontSize: 12),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF21262D),
                  foregroundColor: kAccent,
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

  // ── Normal step tap ────────────────────────────────────────────────────────

  void _handleNormalTap(EcCalibrationStepModel step) {
    _sendStepCommand(step);
    _completeStep(step);
  }

  // ── Bottom bar ─────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: _allDone ? _finishCalibration : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: kAccent,
            disabledBackgroundColor: const Color(0xFF21262D),
            foregroundColor: const Color(0xFF1A1A00),
            disabledForegroundColor: Colors.white38,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_allDone ? Icons.done_all : Icons.hourglass_empty, size: 20),
              const SizedBox(width: 8),
              Text(
                _allDone
                    ? 'Finish Calibration'
                    : 'Complete all steps to finish',
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

  // ── Command log panel ──────────────────────────────────────────────────────

  Widget _buildLogPanel() => Positioned(
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
              color: kSurface,
              borderRadius: BorderRadius.circular(16),
              elevation: 8,
              child: Container(
                constraints: const BoxConstraints(maxHeight: 280),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: kBorder),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(children: [
                        const Icon(Icons.receipt_long,
                            color: kAccent, size: 16),
                        const SizedBox(width: 8),
                        const Text('Command Log',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            )),
                        const Spacer(),
                        Text('${_commandLog.length} sent',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                      ]),
                    ),
                    const Divider(color: kBorder, height: 1),
                    Flexible(
                      child: _commandLog.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: Text('No commands sent yet.',
                                  style: TextStyle(
                                      color: Colors.white38, fontSize: 13)),
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

  Widget _buildLogEntry(CommandLog log) {
    final t = log.sentAt;
    final timeStr =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: log.success ? kAccent : const Color(0xFFFF6B6B),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: kBg,
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
        Expanded(
          child: Text(
            log.stepTitle,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ),
        Text(
          timeStr,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
        ),
      ]),
    );
  }
}
