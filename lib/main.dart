import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  runApp(const PulseMeterApp());
}

const Color midnight = Color(0xFF0F0A24);
const Color deepIndigo = Color(0xFF1B103A);
const Color accentCyan = Color(0xFF3FD6FF);
const Color accentViolet = Color(0xFF9B7BFF);
const Color softWhite = Color(0xFFF2EFFA);
const Color cardSurface = Color(0xFF1A1234);

class PulseMeterApp extends StatelessWidget {
  const PulseMeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentViolet,
      brightness: Brightness.dark,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pulse Meter',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        textTheme: const TextTheme(
          headlineLarge: TextStyle(fontWeight: FontWeight.w800),
          titleLarge: TextStyle(fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      home: const PulseHome(),
    );
  }
}

class SessionEntry {
  SessionEntry({
    required this.title,
    required this.headline,
    required this.summary,
    required this.timestamp,
    required this.duration,
    required this.transcript,
  });

  final String title;
  final String headline;
  final String summary;
  final DateTime timestamp;
  final Duration duration;
  final List<String> transcript;
}

class PulseHome extends StatefulWidget {
  const PulseHome({super.key});

  @override
  State<PulseHome> createState() => _PulseHomeState();
}

class _PulseHomeState extends State<PulseHome> {
  static const int silenceWindowSeconds = 120;

  final List<SessionEntry> _sessions = [];
  final List<String> _liveTranscript = [];
  final TextEditingController _lineController = TextEditingController();
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isListening = false;
  bool _speechReady = false;
  bool _hasPermissions = false;
  String _livePartial = '';
  DateTime? _sessionStart;
  DateTime? _lastSpeechAt;
  Timer? _silenceTicker;
  int _secondsRemaining = silenceWindowSeconds;

  @override
  void dispose() {
    _lineController.dispose();
    _silenceTicker?.cancel();
    _speech.stop();
    super.dispose();
  }

  Future<void> _ensurePermissions() async {
    final micStatus = await Permission.microphone.request();
    final speechStatus = await Permission.speech.request();
    setState(() {
      _hasPermissions = micStatus.isGranted && speechStatus.isGranted;
    });
  }

  Future<void> _initSpeech() async {
    if (_speechReady) return;
    final ready = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' && _isListening) {
          _endSession();
        }
      },
      onError: (_) {
        if (_isListening) {
          _endSession();
        }
      },
    );
    setState(() {
      _speechReady = ready;
    });
  }

  Future<void> _startListening() async {
    await _ensurePermissions();
    if (!_hasPermissions) {
      await _showPermissionHelp();
      return;
    }
    await _initSpeech();
    if (!_speechReady) return;

    setState(() {
      _isListening = true;
      _sessionStart = DateTime.now();
      _lastSpeechAt = DateTime.now();
      _secondsRemaining = silenceWindowSeconds;
      _liveTranscript.clear();
      _livePartial = '';
    });
    _startSilenceTicker();

    await _speech.listen(
      onResult: _handleSpeechResult,
      listenFor: const Duration(minutes: 30),
      pauseFor: const Duration(minutes: 2),
      partialResults: true,
    );
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isEmpty) return;

    setState(() {
      _lastSpeechAt = DateTime.now();
      _secondsRemaining = silenceWindowSeconds;
      if (result.finalResult) {
        _livePartial = '';
        _liveTranscript.add(text);
      } else {
        _livePartial = text;
      }
    });
  }

  void _startSilenceTicker() {
    _silenceTicker?.cancel();
    _silenceTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isListening || _lastSpeechAt == null) {
        return;
      }
      final elapsed = DateTime.now().difference(_lastSpeechAt!).inSeconds;
      final remaining = silenceWindowSeconds - elapsed;
      if (remaining <= 0) {
        _endSession();
      } else {
        setState(() {
          _secondsRemaining = remaining;
        });
      }
    });
  }

  void _addManualLine(String text) {
    if (!_isListening) return;
    if (text.trim().isEmpty) return;

    setState(() {
      _liveTranscript.add(text.trim());
      _lastSpeechAt = DateTime.now();
      _secondsRemaining = silenceWindowSeconds;
    });
  }

  void _endSession() {
    if (!_isListening) return;
    _silenceTicker?.cancel();
    _speech.stop();

    final sessionStart = _sessionStart ?? DateTime.now();
    final transcript = <String>[..._liveTranscript];
    if (_livePartial.isNotEmpty) {
      transcript.add(_livePartial);
    }
    final title = transcript.isNotEmpty ? transcript.first : 'Untitled session';
    final headline = _buildHeadline(transcript);
    final summary = _summarizeTranscript(transcript);

    setState(() {
      _isListening = false;
      _sessions.insert(
        0,
        SessionEntry(
          title: title,
          headline: headline,
          summary: summary,
          timestamp: sessionStart,
          duration: DateTime.now().difference(sessionStart),
          transcript: transcript,
        ),
      );
      _sessionStart = null;
      _lastSpeechAt = null;
      _secondsRemaining = silenceWindowSeconds;
      _liveTranscript.clear();
      _livePartial = '';
      _lineController.clear();
    });
  }

  String _summarizeTranscript(List<String> transcript) {
    if (transcript.isEmpty) {
      return 'No notes captured.';
    }

    final fullText = transcript.join(' ');
    final sentences = fullText
        .split(RegExp(r'(?<=[.!?])\\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (sentences.isEmpty) {
      return transcript.first;
    }

    final stopWords = <String>{
      'the',
      'and',
      'that',
      'this',
      'with',
      'have',
      'from',
      'about',
      'were',
      'what',
      'when',
      'your',
      'you',
      'for',
      'are',
      'but',
      'just',
      'like',
      'then',
      'into',
      'also',
      'they',
      'them',
      'there',
      'their',
      'will',
      'would',
      'should',
      'could',
      'maybe',
      'okay',
    };
    final keywordSignals = <String>[
      'decide',
      'decision',
      'agree',
      'plan',
      'next',
      'action',
      'follow up',
      'deadline',
      'owner',
      'risk',
      'blocker',
    ];

    final wordCounts = <String, int>{};
    for (final sentence in sentences) {
      for (final raw in sentence.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
        if (raw.length < 4 || stopWords.contains(raw)) continue;
        wordCounts[raw] = (wordCounts[raw] ?? 0) + 1;
      }
    }

    final scored = <MapEntry<String, int>>[];
    for (final sentence in sentences) {
      final lower = sentence.toLowerCase();
      var score = 0;
      for (final key in keywordSignals) {
        if (lower.contains(key)) {
          score += 3;
        }
      }
      for (final raw in lower.split(RegExp(r'[^a-z0-9]+'))) {
        score += (wordCounts[raw] ?? 0);
      }
      scored.add(MapEntry(sentence, score));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    final topSentences = scored.take(2).map((e) => e.key).toList();

    final actionItems = sentences.where((s) {
      final lower = s.toLowerCase();
      return lower.contains('action') ||
          lower.contains('next step') ||
          lower.contains('follow up') ||
          lower.startsWith('to do') ||
          lower.startsWith('todo');
    }).toList();

    final summaryLines = <String>[];
    final core = topSentences.join(' ');
    final cleaned = core
        .replaceAll(RegExp(r'\\b(you know|kind of|sort of|maybe|basically|okay)\\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\\s{2,}'), ' ')
        .trim();
    final shortened = cleaned.length > 180 ? '${cleaned.substring(0, 177)}...' : cleaned;
    summaryLines.add(shortened.isEmpty ? _keywordSummary(wordCounts) : shortened);
    if (actionItems.isNotEmpty) {
      summaryLines.add('Action items: ${actionItems.join(' | ')}');
    }

    return summaryLines.join(' ');
  }

  String _keywordSummary(Map<String, int> wordCounts) {
    final sorted = wordCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(6).map((e) => e.key).toList();
    if (top.isEmpty) return 'Key topics captured.';
    return 'Key topics: ${top.join(', ')}.';
  }

  String _buildHeadline(List<String> transcript) {
    if (transcript.isEmpty) return 'Meeting recap';
    final text = transcript.join(' ').toLowerCase();
    final topics = <String, List<String>>{
      'Planning & next steps': ['plan', 'next', 'schedule', 'timeline', 'roadmap'],
      'Decisions made': ['decide', 'decision', 'agreed', 'approve'],
      'Risks & blockers': ['risk', 'blocker', 'issue', 'problem'],
      'Customer updates': ['customer', 'client', 'feedback', 'support'],
      'Product updates': ['feature', 'release', 'build', 'ship', 'product'],
    };

    for (final entry in topics.entries) {
      for (final keyword in entry.value) {
        if (text.contains(keyword)) return entry.key;
      }
    }

    final first = transcript.first.split(' ').take(6).join(' ');
    return first.isEmpty ? 'Meeting recap' : first;
  }

  Future<void> _showPermissionHelp() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enable microphone + speech',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: softWhite,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pulse Meter needs access to transcribe live notes. '
                'Open Settings to allow Microphone and Speech Recognition.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: softWhite,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text('Not now'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        openAppSettings();
                        Navigator.pop(context);
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: accentViolet,
                        foregroundColor: softWhite,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text('Open Settings'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  String _formatSilenceCountdown(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String _permissionStatus() {
    if (_hasPermissions) {
      return 'Microphone & speech enabled';
    }
    return 'Microphone or speech access required';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [midnight, deepIndigo],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            'Pulse Meter',
            style: TextStyle(fontWeight: FontWeight.w700, color: softWhite),
          ),
          actions: [
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                _permissionStatus(),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            _buildHero(),
            const SizedBox(height: 20),
            _buildLiveSessionCard(),
            const SizedBox(height: 28),
            _buildSectionHeader('Previous notes'),
            const SizedBox(height: 12),
            if (_sessions.isEmpty) _buildEmptyState(),
            for (final session in _sessions) _buildSessionCard(session),
          ],
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'Capture conversations',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: softWhite,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Pulse Meter listens, transcribes, and saves a clean summary once the room goes quiet.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildLiveSessionCard() {
    final liveLines = [..._liveTranscript];
    if (_livePartial.isNotEmpty) {
      liveLines.add(_livePartial);
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 18,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isListening ? 'Listening now' : 'Ready to listen',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: softWhite,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isListening
                        ? 'Silence auto-stop in ${_formatSilenceCountdown(_secondsRemaining)}'
                        : 'Auto-stop after 2 minutes of silence',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    colors: _isListening
                        ? [accentCyan, accentViolet]
                        : [Colors.white24, Colors.white10],
                  ),
                ),
                child: Text(
                  _isListening ? 'LIVE' : 'IDLE',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            height: 160,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: liveLines.isEmpty
                ? const Center(
                    child: Text(
                      'Transcript will appear here as you speak.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    itemCount: liveLines.length,
                    itemBuilder: (context, index) {
                      final line = liveLines[index];
                      final isPartial = _livePartial.isNotEmpty && index == liveLines.length - 1;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          line,
                          style: TextStyle(
                            color: isPartial ? Colors.white70 : softWhite,
                            fontSize: 13,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lineController,
                  style: const TextStyle(color: softWhite),
                  decoration: InputDecoration(
                    hintText: _isListening
                        ? 'Optional: add a manual note'
                        : 'Start listening to add notes',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white10,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (value) {
                    _addManualLine(value);
                    _lineController.clear();
                  },
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _isListening
                    ? () {
                        _addManualLine(_lineController.text);
                        _lineController.clear();
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accentCyan,
                  foregroundColor: midnight,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Icon(Icons.send_rounded),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _isListening ? null : _startListening,
                  style: FilledButton.styleFrom(
                    backgroundColor: accentViolet,
                    foregroundColor: softWhite,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('Start listening'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _isListening ? _endSession : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: softWhite,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('End session'),
                ),
              ),
            ],
          ),
          if (!_hasPermissions)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                onPressed: _ensurePermissions,
                child: const Text('Enable microphone + speech'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: softWhite,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(18),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Text(
        'No sessions yet. Start listening to capture your first notes.',
        style: TextStyle(color: Colors.white60),
      ),
    );
  }

  Widget _buildSessionCard(SessionEntry session) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SessionDetailScreen(session: session),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 16,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    session.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: midnight,
                    ),
                  ),
                ),
                Text(
                  _formatDuration(session.duration),
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              session.headline,
              style: const TextStyle(
                color: accentViolet,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              session.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: accentViolet.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Transcript',
                    style: TextStyle(
                      color: accentViolet,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${session.timestamp.month}/${session.timestamp.day}/${session.timestamp.year}',
                  style: const TextStyle(color: Colors.black45, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SessionDetailScreen extends StatelessWidget {
  const SessionDetailScreen({super.key, required this.session});

  final SessionEntry session;

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [midnight, deepIndigo],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            'Session details',
            style: TextStyle(color: softWhite, fontWeight: FontWeight.w700),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Text(
              session.headline,
              style: const TextStyle(
                color: accentCyan,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              session.title,
              style: const TextStyle(
                color: softWhite,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${session.timestamp.month}/${session.timestamp.day}/${session.timestamp.year} · ${_formatDuration(session.duration)}',
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 20),
            _DetailCard(
              title: 'Summary',
              child: Text(
                session.summary,
                style: const TextStyle(color: softWhite),
              ),
            ),
            const SizedBox(height: 16),
            _DetailCard(
              title: 'Full transcript',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: session.transcript
                    .map(
                      (line) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          line,
                          style: const TextStyle(color: softWhite),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 18,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
