import 'dart:async';
import 'package:flutter/material.dart';

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
    required this.summary,
    required this.timestamp,
    required this.duration,
    required this.transcript,
  });

  final String title;
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

  bool _isListening = false;
  DateTime? _sessionStart;
  DateTime? _lastSpeechAt;
  Timer? _silenceTicker;
  int _secondsRemaining = silenceWindowSeconds;

  @override
  void dispose() {
    _lineController.dispose();
    _silenceTicker?.cancel();
    super.dispose();
  }

  void _startListening() {
    setState(() {
      _isListening = true;
      _sessionStart = DateTime.now();
      _lastSpeechAt = DateTime.now();
      _secondsRemaining = silenceWindowSeconds;
      _liveTranscript.clear();
    });
    _startSilenceTicker();
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

  void _addTranscriptLine(String text) {
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

    final sessionStart = _sessionStart ?? DateTime.now();
    final transcript = List<String>.from(_liveTranscript);
    final title = transcript.isNotEmpty ? transcript.first : 'Untitled session';
    final summary = transcript.length > 1
        ? transcript.sublist(1).join(' ').trim()
        : 'No additional notes.';

    setState(() {
      _isListening = false;
      _sessions.insert(
        0,
        SessionEntry(
          title: title,
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
      _lineController.clear();
    });
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
              child: const Text('Listening notes', style: TextStyle(fontSize: 12)),
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
            height: 140,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: _liveTranscript.isEmpty
                ? const Center(
                    child: Text(
                      'Transcript will appear here as you speak.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.builder(
                    itemCount: _liveTranscript.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          _liveTranscript[index],
                          style: const TextStyle(color: softWhite, fontSize: 13),
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
                        ? 'Type a note to simulate speech'
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
                    _addTranscriptLine(value);
                    _lineController.clear();
                  },
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _isListening
                    ? () {
                        _addTranscriptLine(_lineController.text);
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
    return Container(
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
    );
  }
}
