import 'dart:async';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'SettingsScreen.dart';
import 'app_background.dart';
import 'dashboard_screen.dart';
import 'graphic.dart';
import '../translations.dart';

class ChartsScreen extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const ChartsScreen({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  final Translations _translations = Translations();
  static const Color _emerald = Color(0xFF34D399);

  // ── Firebase refs — one per sensor node ───────────────────────────────────
  final DatabaseReference _ecRef = FirebaseDatabase.instance.ref('capteurs/ec');
  final DatabaseReference _phRef = FirebaseDatabase.instance.ref('capteurs/ph');
  final DatabaseReference _tempRef =
      FirebaseDatabase.instance.ref('capteurs/temp');
  final DatabaseReference _turbRef =
      FirebaseDatabase.instance.ref('capteurs/turbidite');

  StreamSubscription<DatabaseEvent>? _ecSub;
  StreamSubscription<DatabaseEvent>? _phSub;
  StreamSubscription<DatabaseEvent>? _tempSub;
  StreamSubscription<DatabaseEvent>? _turbSub;

  // ── Sensor values ─────────────────────────────────────────────────────────
  double temperature = 0;
  double turbidite = 0;
  double ph = 0;
  double ec = 0;

  // ── Scoring & status ──────────────────────────────────────────────────────
  String overallScoreText = "0";
  String status = "Excellent";
  Color statusColor = _emerald;
  String aiRecommendation = "Waiting for sensor data…";
  List<String> activeIssues = [];

  // ── Chat ──────────────────────────────────────────────────────────────────
  final List<Map<String, String>> _messages = [];
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  bool _isAiTyping = false;

  // ── Firebase AI (Gemini) ──────────────────────────────────────────────────
  late final GenerativeModel _geminiModel;
  late ChatSession _chatSession;

  int _selectedIndex = 2;

  String _tr(String key) {
    _translations.setLocale(Localizations.localeOf(context));
    return _translations.translate(key);
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initGemini();
    _startTempListener();
    _startPhListener();
    _startEcListener();
    _startTurbListener();
  }

  @override
  void dispose() {
    _ecSub?.cancel();
    _phSub?.cancel();
    _tempSub?.cancel();
    _turbSub?.cancel();
    _chatController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Firebase listeners
  //  Each node: { date, time, timestamp, value }
  // ─────────────────────────────────────────────────────────────────────────

  void _startTempListener() {
    _tempSub = _tempRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      setState(() => temperature = _parseDouble(snap.child('value').value));
      _analyzeCoolingSystem();
    }, onError: (Object e, StackTrace s) {
      debugPrint('ChartsScreen Temp stream error: $e');
    });
  }

  void _startPhListener() {
    _phSub = _phRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      setState(() => ph = _parseDouble(snap.child('value').value));
      _analyzeCoolingSystem();
    }, onError: (Object e, StackTrace s) {
      debugPrint('ChartsScreen pH stream error: $e');
    });
  }

  void _startEcListener() {
    _ecSub = _ecRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      setState(() => ec = _parseDouble(snap.child('value').value));
      _analyzeCoolingSystem();
    }, onError: (Object e, StackTrace s) {
      debugPrint('ChartsScreen EC stream error: $e');
    });
  }

  void _startTurbListener() {
    _turbSub = _turbRef.onValue.listen((event) {
      final snap = event.snapshot;
      if (!snap.exists || !mounted) return;
      setState(() => turbidite = _parseDouble(snap.child('value').value));
      _analyzeCoolingSystem();
    }, onError: (Object e, StackTrace s) {
      debugPrint('ChartsScreen Turbidity stream error: $e');
    });
  }

  double _parseDouble(dynamic v) =>
      double.tryParse(v?.toString() ?? '0') ?? 0.0;

  // ─────────────────────────────────────────────────────────────────────────
  //  Gemini initialisation
  // ─────────────────────────────────────────────────────────────────────────

  void _initGemini() {
    _geminiModel = FirebaseAI.googleAI().generativeModel(
      model: 'gemini-2.5-flash-lite',
      systemInstruction: Content.system('''
You are CoolBot, a friendly and intelligent assistant embedded in an industrial water cooling monitoring app for Husky injection-moulding machines.

🌟 YOUR PERSONALITY
Warm, approachable, and conversational.
Greet naturally (e.g. "Hey! How can I help you today? 😊").
You can handle general conversation (greetings, small talk, general knowledge).
Do NOT force cooling-related topics unless the user asks about them.

⚠️ STRICT OUTPUT RULES
NEVER repeat or restate the sensor data block.
NEVER start by listing readings (e.g. avoid: "Your pH is...").
Jump directly to the answer.
Be concise: answer ONLY what was asked.
No unnecessary introduction, no summary, no closing phrases.

🧠 EXPERT ROLE (WHEN SENSOR DATA IS PROVIDED)
When the user asks about the cooling system:
  - Use exact numeric values and compare them to limits.
    Example: "pH 6.8 is 0.7 below the minimum of 7.5"
  - Quantify the industrial risk clearly.
    Example: "At this level, corrosion rate can be ~2–3× higher"
  - Provide clear corrective action:
      • Product category (not brand)
      • Dosage guideline
      • Recheck timing
  - Prioritize actions by urgency (most critical first).
  - NEVER give vague advice like "monitor the system"
    → Always include a specific threshold or timeline.

📊 OPERATING LIMITS (HUSKY COOLING SYSTEM)
  EC (Conductivity) : Ideal < 300 µs/cm | Acceptable < 500 µs/cm
  pH                : ${kSensorRanges['ph']!.min} – ${kSensorRanges['ph']!.max}
  Turbidity         : < ${kSensorRanges['turbidite']!.max} ${kSensorRanges['turbidite']!.unit}  (fouling / biofilm risk > 2 NTU)
  Temperature       : ${kSensorRanges['temperature']!.min} – ${kSensorRanges['temperature']!.max} ${kSensorRanges['temperature']!.unit}

🧪 WATER TREATMENT LOGIC
When correction is needed:
  • Use softened or slightly demineralized water → reduces scaling and conductivity.
  • Add a corrosion inhibitor (molybdate- or phosphate-based) → typical initial dose: 100–300 ppm.
  • Add a biocide → shock dose: 50–100 ppm | maintenance dose: 10–20 ppm.
  • Add glycol (30–40%) ONLY if there is a freezing risk (temperature < ${kSensorRanges['temperature']!.min} ${kSensorRanges['temperature']!.unit}).

⚙️ DECISION RULES
Only recommend treatment when limits are exceeded:
  EC > 500 µs/cm             → scaling / contamination risk
  pH < ${kSensorRanges['ph']!.min}                   → corrosion risk
  pH > ${kSensorRanges['ph']!.max}                   → scaling / caustic risk
  Turbidity > 100 NTU          → fouling / biofilm risk
  Turbidity > ${kSensorRanges['turbidite']!.max} ${kSensorRanges['turbidite']!.unit}        → critical filter issue
  Temperature < ${kSensorRanges['temperature']!.min} ${kSensorRanges['temperature']!.unit}   → under-cooling / freezing risk
  Temperature > ${kSensorRanges['temperature']!.max} ${kSensorRanges['temperature']!.unit}   → over-heating / efficiency loss

⏱️ RESPONSE FORMAT (MANDATORY STYLE)
Each recommendation must:
  1. State the deviation clearly (value vs. limit).
  2. Provide a corrective action with dosage.
  3. Include a recheck time.
'''),
    );
    _chatSession = _geminiModel.startChat();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Scoring sub-scores
  //  Thresholds read from kSensorRanges where possible
  // ─────────────────────────────────────────────────────────────────────────

  double _phSubScore() {
    final min = kSensorRanges['ph']!.min; // 7.5
    final max = kSensorRanges['ph']!.max; //9
    if (ph >= min && ph <= max) return 100;
    if (ph >= 6.0 && ph < min) return 60;
    if (ph >= 5.5 && ph < 6.0) return 30;
    if (ph < 5.5) return 0;
    if (ph > max && ph <= 9.0) return 60;
    return 20;
  }

  double _ecSubScore() {
    // ec is in µs/cm: ideal < 300, acceptable < 500
    if (ec <= 300) return 100;
    if (ec <= 500) return 75;
    if (ec <= 1000) return 40;
    if (ec <= 2000) return 20;
    return 0;
  }

  double _tempSubScore() {
    final min = kSensorRanges['temperature']!.min; // 10
    final max = kSensorRanges['temperature']!.max; // 18
    if (temperature >= min && temperature <= max) return 100;
    if (temperature > max && temperature <= max + 4) return 75;
    if (temperature > max + 4 && temperature <= max + 12) return 40;
    if (temperature > max + 12) return 10;
    if (temperature >= min - 3 && temperature < min) return 75;
    return 50;
  }

  double _turbSubScore() {
    final maxNorm = kSensorRanges['turbidite']!.max; // 100 NTU
    if (turbidite <= maxNorm) return 100;
    if (turbidite <= maxNorm * 1.5) return 80;
    if (turbidite <= maxNorm * 25) return 40; // up to 100 NTU
    if (turbidite <= maxNorm * 250) return 10; // up to 1000 NTU
    return 0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Main analysis
  // ─────────────────────────────────────────────────────────────────────────

  void _analyzeCoolingSystem() {
    final double phScore = _phSubScore();
    final double ecScore = _ecSubScore();
    final double tempScore = _tempSubScore();
    final double turbScore = _turbSubScore();

    double coolingIndex = (phScore * 0.35) +
        (ecScore * 0.30) +
        (tempScore * 0.20) +
        (turbScore * 0.15);

    final double minSub = [phScore, ecScore, tempScore, turbScore]
        .reduce((a, b) => a < b ? a : b);
    if (minSub == 0) {
      coolingIndex = coolingIndex.clamp(0, 35);
    } else if (minSub <= 30) coolingIndex = coolingIndex.clamp(0, 55);

    String newStatus;
    Color newColor;
    if (coolingIndex >= 90) {
      newStatus = "Excellent";
      newColor = _emerald;
    } else if (coolingIndex >= 75) {
      newStatus = "Good";
      newColor = Colors.green;
    } else if (coolingIndex >= 56) {
      newStatus = "Fair";
      newColor = Colors.orange;
    } else if (coolingIndex >= 36) {
      newStatus = "Warning";
      newColor = Colors.amber;
    } else {
      newStatus = "Critical";
      newColor = Colors.red;
    }

    final phMin = kSensorRanges['ph']!.min;
    final phMax = kSensorRanges['ph']!.max;
    final tMin = kSensorRanges['temperature']!.min;
    final tMax = kSensorRanges['temperature']!.max;
    final turbMax = kSensorRanges['turbidite']!.max;

    List<String> issues = [];

    // — pH —
    if (ph < phMin - 1.0) {
      issues.add(
          "pH ${ph.toStringAsFixed(2)} — CRITICAL: ${(phMin - ph).toStringAsFixed(2)} units below minimum ($phMin). Corrosion rate ×5. Immediate alkaline buffer treatment required.");
    } else if (ph < phMin - 0.5) {
      issues.add(
          "pH ${ph.toStringAsFixed(2)} — CRITICAL: ${(phMin - ph).toStringAsFixed(2)} units below minimum ($phMin). High corrosion risk. Add alkaline buffer now.");
    } else if (ph < phMin) {
      issues.add(
          "pH ${ph.toStringAsFixed(2)} — WARNING: ${(phMin - ph).toStringAsFixed(2)} units below minimum ($phMin). Mild corrosion risk. Treat within 24 h.");
    } else if (ph > phMax + 0.5) {
      issues.add(
          "pH ${ph.toStringAsFixed(2)} — CRITICAL: ${(ph - phMax).toStringAsFixed(2)} units above maximum ($phMax). Caustic attack on aluminium. Immediate acid correction required.");
    } else if (ph > phMax) {
      issues.add(
          "pH ${ph.toStringAsFixed(2)} — WARNING: ${(ph - phMax).toStringAsFixed(2)} units above maximum ($phMax). Scaling risk. Add pH reducer within 24 h.");
    }

    // — EC (Conductivity in mS/cm) —
    if (ec > 2000.0) {
      issues.add(
          "EC ${ec.toStringAsFixed(2)} µs/cm — CRITICAL: ${(ec - 2000.0).toStringAsFixed(2)} µs/cm above limit (2000.0). Replace circuit water immediately.");
    } else if (ec > 1000.0) {
      issues.add(
          "EC ${ec.toStringAsFixed(2)} µs/cm — CRITICAL: ${(ec - 1000.0).toStringAsFixed(2)} µs/cm above limit (1000.0). Partial water replacement required within 24 h.");
    } else if (ec > 500) {
      issues.add(
          "EC ${ec.toStringAsFixed(2)} µs/cm — WARNING: ${(ec - 500).toStringAsFixed(2)} µs/cm above acceptable limit (500). Plan water change within 48 h.");
    } else if (ec > 300) {
      issues.add(
          "EC ${ec.toStringAsFixed(2)} µs/cm — NOTICE: Above ideal limit (300 µs/cm). Monitor and plan demineralization.");
    }

    // — Temperature —
    if (temperature > tMax + 12) {
      issues.add(
          "Temperature ${temperature.toStringAsFixed(1)} °C — CRITICAL: ${(temperature - tMax).toStringAsFixed(1)} °C above maximum ($tMax °C). Equipment shutdown risk. Increase coolant flow immediately.");
    } else if (temperature > tMax + 4) {
      issues.add(
          "Temperature ${temperature.toStringAsFixed(1)} °C — CRITICAL: ${(temperature - tMax).toStringAsFixed(1)} °C above maximum ($tMax °C). Verify chiller output immediately.");
    } else if (temperature > tMax) {
      issues.add(
          "Temperature ${temperature.toStringAsFixed(1)} °C — WARNING: ${(temperature - tMax).toStringAsFixed(1)} °C above maximum ($tMax °C). Check chiller performance within 4 h.");
    } else if (temperature < tMin - 3) {
      issues.add(
          "Temperature ${temperature.toStringAsFixed(1)} °C — WARNING: ${(tMin - temperature).toStringAsFixed(1)} °C below minimum ($tMin °C). Freezing risk. Verify glycol concentration (30–40%).");
    } else if (temperature < tMin) {
      issues.add(
          "Temperature ${temperature.toStringAsFixed(1)} °C — NOTICE: ${(tMin - temperature).toStringAsFixed(1)} °C below minimum ($tMin °C). Check chiller set-point.");
    }

    // — Turbidity —
    if (turbidite > turbMax * 250) {
      issues.add(
          "Turbidity ${turbidite.toStringAsFixed(2)} NTU — CRITICAL: Filter blocked or failed. Replace filter immediately.");
    } else if (turbidite > turbMax * 25) {
      issues.add(
          "Turbidity ${turbidite.toStringAsFixed(2)} NTU — CRITICAL: Filter severely clogged. Clean or replace now.");
    } else if (turbidite > turbMax) {
      issues.add(
          "Turbidity ${turbidite.toStringAsFixed(2)} NTU — WARNING: ${(turbidite - turbMax).toStringAsFixed(2)} NTU above limit ($turbMax NTU). Clean filter within 24 h. Add biocide maintenance dose (10–20 ppm). Monitor biofilm.");
    }

    setState(() {
      overallScoreText = coolingIndex.toStringAsFixed(0);
      status = newStatus;
      statusColor = newColor;
      aiRecommendation = issues.isEmpty
          ? "All parameters within norms. No action required."
          : issues.join('\n\n');
      activeIssues = issues;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Gemini chat
  // ─────────────────────────────────────────────────────────────────────────

  bool _isCoolingRelated(String text) {
    final lower = text.toLowerCase();
    const keywords = [
      'ph',
      'temp',
      'temperature',
      'conduct',
      'ec',
      'turbid',
      'cool',
      'water',
      'score',
      'status',
      'sensor',
      'husky',
      'circuit',
      'filter',
      'corros',
      'scal',
      'chiller',
      'flow',
      'issue',
      'problem',
      'fix',
      'treat',
      'chemical',
      'reading',
      'value',
      'system',
      'biofilm',
      'glycol',
      'inhibitor',
      'biocide',
    ];
    return keywords.any((k) => lower.contains(k));
  }

  Future<void> _sendToGemini(String userMessage) async {
    final String messageToSend;

    if (_isCoolingRelated(userMessage)) {
      // Use kSensorRanges for the limit labels sent to the model
      final phRange = kSensorRanges['ph']!;
      final tRange = kSensorRanges['temperature']!;
      final turbRange = kSensorRanges['turbidite']!;
      final ecRange = kSensorRanges['ec']!;

      messageToSend = '''
=== REAL-TIME SENSOR DATA ===
• Cooling Score  : $overallScoreText / 100  →  $status
• Temperature    : ${temperature.toStringAsFixed(2)} ${tRange.unit}      (limit: ${tRange.min}–${tRange.max} ${tRange.unit})
• EC (Conductivity): ${ec.toStringAsFixed(3)} ${ecRange.unit}   (ideal: < 300 ${ecRange.unit} | max: 500 ${ecRange.unit})
• Turbidity      : ${turbidite.toStringAsFixed(3)} ${turbRange.unit}     (limit: < ${turbRange.max} ${turbRange.unit})
• pH             : ${ph.toStringAsFixed(3)}                    (range: ${phRange.min}–${phRange.max})

=== ACTIVE ISSUES ===
${activeIssues.isEmpty ? "None — all parameters nominal." : activeIssues.join('\n')}

=== USER QUESTION ===
$userMessage
''';
    } else {
      messageToSend = userMessage;
    }

    setState(() => _isAiTyping = true);

    try {
      final response =
          await _chatSession.sendMessage(Content.text(messageToSend));
      final aiAnswer = response.text?.trim() ?? "No response from Gemini.";
      setState(() {
        _messages.add({'role': 'assistant', 'content': aiAnswer});
        _isAiTyping = false;
      });
    } catch (e) {
      setState(() {
        _messages.add({'role': 'assistant', 'content': 'Gemini error: $e'});
        _isAiTyping = false;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController
            .jumpTo(_chatScrollController.position.maxScrollExtent);
      }
    });
  }

  void _sendMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty || _isAiTyping) return;
    setState(() => _messages.add({'role': 'user', 'content': text}));
    _chatController.clear();
    _sendToGemini(text);
  }

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
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => Graphic(
                    currentLocale: widget.currentLocale,
                    onLocaleChanged: widget.onLocaleChanged)));
        return;
      case 2:
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
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    _tr('cooling_recommendation'),
                    style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Score Card ────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: statusColor.withOpacity(0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_tr('efficiency_score'),
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 14)),
                            Text('$overallScoreText/100',
                                style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: statusColor)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('${_tr('status')}: $status',
                            style: TextStyle(
                                color: statusColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        Text(aiRecommendation,
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                height: 1.6)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Sensor Grid ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_tr('sensor_readings'),
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                      const SizedBox(height: 12),
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        children: [
                          _buildSensorCard(
                            _tr('temperature'),
                            temperature.toStringAsFixed(1),
                            kSensorRanges['temperature']!.unit,
                            _tempSubScore() <= 10
                                ? Colors.red
                                : _tempSubScore() < 100
                                    ? Colors.orange
                                    : Colors.green,
                            limit:
                                '${kSensorRanges['temperature']!.min}–${kSensorRanges['temperature']!.max} ${kSensorRanges['temperature']!.unit}',
                          ),
                          _buildSensorCard(
                            _tr('conductivity'),
                            ec.toStringAsFixed(3),
                            kSensorRanges['ec']!.unit,
                            _ecSubScore() <= 20
                                ? Colors.red
                                : _ecSubScore() < 100
                                    ? Colors.orange
                                    : Colors.blue,
                            limit: '< 0.3 ${kSensorRanges['ec']!.unit}',
                          ),
                          _buildSensorCard(
                            _tr('turbidity'),
                            turbidite.toStringAsFixed(2),
                            kSensorRanges['turbidite']!.unit,
                            _turbSubScore() <= 10
                                ? Colors.red
                                : _turbSubScore() < 100
                                    ? Colors.orange
                                    : Colors.teal,
                            limit:
                                '< ${kSensorRanges['turbidite']!.max} ${kSensorRanges['turbidite']!.unit}',
                          ),
                          _buildSensorCard(
                            'pH',
                            ph.toStringAsFixed(2),
                            kSensorRanges['ph']!.unit,
                            _phSubScore() == 0
                                ? Colors.red
                                : _phSubScore() < 100
                                    ? Colors.orange
                                    : const Color(0xFF0BB511),
                            limit:
                                '${kSensorRanges['ph']!.min}–${kSensorRanges['ph']!.max}',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ── Chat ──────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(_tr('chat_with_ai'),
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white)),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: Colors.blue.withOpacity(0.5)),
                            ),
                            child: const Text('Gemini',
                                style: TextStyle(
                                    color: Colors.blueAccent,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        height: 320,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: Colors.white.withOpacity(0.15)),
                        ),
                        child: _messages.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.waving_hand_rounded,
                                          color: Colors.white.withOpacity(0.3),
                                          size: 32),
                                      const SizedBox(height: 10),
                                      Text(
                                        "Hi! I'm CoolBot 👋\n"
                                        "Say hello or ask me anything about your cooling system.",
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            color:
                                                Colors.white.withOpacity(0.4),
                                            fontSize: 13,
                                            height: 1.5),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : ListView.builder(
                                controller: _chatScrollController,
                                padding: const EdgeInsets.all(8),
                                itemCount:
                                    _messages.length + (_isAiTyping ? 1 : 0),
                                itemBuilder: (context, index) {
                                  if (_isAiTyping &&
                                      index == _messages.length) {
                                    return Align(
                                      alignment: Alignment.centerLeft,
                                      child: Container(
                                        margin: const EdgeInsets.all(8),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.withOpacity(0.3),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 1.5,
                                                  color: Colors.white54),
                                            ),
                                            SizedBox(width: 8),
                                            Text('CoolBot is typing…',
                                                style: TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12,
                                                    fontStyle:
                                                        FontStyle.italic)),
                                          ],
                                        ),
                                      ),
                                    );
                                  }

                                  final msg = _messages[index];
                                  final isUser = msg['role'] == 'user';
                                  return Align(
                                    alignment: isUser
                                        ? Alignment.centerRight
                                        : Alignment.centerLeft,
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      padding: const EdgeInsets.all(10),
                                      constraints: BoxConstraints(
                                          maxWidth: MediaQuery.of(context)
                                                  .size
                                                  .width *
                                              0.78),
                                      decoration: BoxDecoration(
                                        color: isUser
                                            ? Colors.blue.withOpacity(0.7)
                                            : Colors.white.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(msg['content'] ?? '',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              height: 1.5)),
                                    ),
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _chatController,
                              style: const TextStyle(color: Colors.white),
                              onSubmitted: (_) => _sendMessage(),
                              decoration: InputDecoration(
                                hintText: 'Say hi or ask about your system…',
                                hintStyle: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 13),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FloatingActionButton(
                            mini: true,
                            onPressed: _isAiTyping ? null : _sendMessage,
                            backgroundColor: _isAiTyping ? Colors.grey : null,
                            child: _isAiTyping
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.send),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
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
      ),
    );
  }

  // ── Sensor card ──────────────────────────────────────────────────────────
  Widget _buildSensorCard(
    String title,
    String value,
    String unit,
    Color color, {
    String limit = '',
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.09),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
          if (limit.isNotEmpty)
            Text(limit,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.35), fontSize: 10)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          Text(unit,
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
          const Spacer(),
        ],
      ),
    );
  }
}
