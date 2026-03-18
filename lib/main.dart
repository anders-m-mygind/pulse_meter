import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  runApp(const PulseMeterApp());
}

const Color midnight = Color(0xFF0F0A24);
const Color deepIndigo = Color(0xFF1B103A);
const Color accentCyan = Color(0xFF73E9FF);
const Color accentMagenta = Color(0xFFFF3DAD);
const Color accentViolet = Color(0xFF7C4DFF);
const Color liveGreen = Color(0xFF39F58F);
const Color idleAmber = Color(0xFFFFCA6A);
const Color softWhite = Color(0xFFF2EFFA);
const Color cardSurface = Color(0xFF1A1234);

enum MeetingProcessingState { pending, sending, sent, processed, failed }

const String _meetingProcessEndpoint = String.fromEnvironment(
  'MEETING_PROCESS_ENDPOINT',
  defaultValue: 'http://127.0.0.1:8080/v1/meeting-notes/process',
);
const String _speechLocalePreferenceKey = 'preferred_speech_locale_id';

class PulseMeterApp extends StatelessWidget {
  const PulseMeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accentMagenta,
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
    required this.id,
    required this.title,
    required this.headline,
    required this.summary,
    required this.timestamp,
    required this.duration,
    required this.transcript,
    this.whiteboardSnapshots = const [],
    this.whiteboardOcrBySnapshot = const {},
    this.processingState = MeetingProcessingState.pending,
    this.processingMessage = 'Not sent to backend',
  });

  final String id;
  String title;
  String headline;
  String summary;
  final DateTime timestamp;
  final Duration duration;
  final List<String> transcript;
  final List<String> whiteboardSnapshots;
  final Map<String, String> whiteboardOcrBySnapshot;
  MeetingProcessingState processingState;
  String processingMessage;

  bool get isSent =>
      processingState == MeetingProcessingState.sent ||
      processingState == MeetingProcessingState.processed;

  bool get isProcessed => processingState == MeetingProcessingState.processed;
}

class PulseHome extends StatefulWidget {
  const PulseHome({super.key});

  @override
  State<PulseHome> createState() => _PulseHomeState();
}

class _PulseHomeState extends State<PulseHome> with WidgetsBindingObserver {
  static const Duration _maxListenWindow = Duration(minutes: 1);
  static const Duration _silencePauseWindow = Duration(seconds: 8);
  static const Duration _watchdogInterval = Duration(seconds: 2);
  static const Duration _restartCooldownWindow = Duration(seconds: 2);
  static const Duration _whiteboardSnapshotInterval = Duration(seconds: 30);
  static const Duration _partialUiThrottleWindow = Duration(
    milliseconds: 140,
  );

  final List<SessionEntry> _sessions = [];
  String _liveTranscript = '';
  final List<String> _liveWhiteboardSnapshots = [];
  final Map<String, String> _liveWhiteboardOcrByPath = {};
  final stt.SpeechToText _speech = stt.SpeechToText();
  final TextRecognizer _whiteboardTextRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  final ScrollController _scrollController = ScrollController();
  final ScrollController _liveTranscriptController = ScrollController();
  final GlobalKey _previousMeetingsKey = GlobalKey();

  bool _isListening = false;
  bool _speechReady = false;
  bool _hasPermissions = false;
  String _livePartial = '';
  String _speechLocaleId = 'en_US';
  String _speechLocaleLabel = 'English (United States)';
  String? _preferredSpeechLocaleId;
  stt.LocaleName? _systemSpeechLocale;
  List<stt.LocaleName> _availableSpeechLocales = const [];
  String _lastFinalTranscript = '';
  bool _isAutoRestarting = false;
  bool _isRotatingSession = false;
  bool _isSpeechTransitioning = false;
  bool _showPreviousMeetings = false;
  bool _watchWhiteboardMode = false;
  bool _hasCameraPermission = false;
  bool _isPreparingWhiteboardCamera = false;
  bool _isCapturingWhiteboardSnapshot = false;
  String _whiteboardStatus = 'Whiteboard watch is off';
  DateTime? _sessionStart;
  DateTime? _lastSpeechStopAt;
  String? _activeSessionId;
  Timer? _watchdogTimer;
  Timer? _proactiveRotateTimer;
  Timer? _whiteboardSnapshotTimer;
  CameraController? _whiteboardCamera;
  DateTime? _lastPartialUiUpdateAt;
  bool _isTranscriptScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadSpeechLocalePreference());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningSupervision();
    _stopWhiteboardCapture(disposeCamera: true);
    unawaited(_whiteboardTextRecognizer.close());
    _scrollController.dispose();
    _liveTranscriptController.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isListening && !_speech.isListening) {
        unawaited(_resumeListening());
      }
      if (_isListening && _watchWhiteboardMode) {
        unawaited(_startWhiteboardCapture());
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _stopWhiteboardCapture(disposeCamera: true);
    }
  }

  Future<void> _ensurePermissions() async {
    final micStatus = await Permission.microphone.request();
    final speechStatus = await Permission.speech.request();
    final cameraStatus = _watchWhiteboardMode
        ? await Permission.camera.request()
        : PermissionStatus.granted;
    setState(() {
      _hasPermissions = micStatus.isGranted && speechStatus.isGranted;
      _hasCameraPermission = _watchWhiteboardMode && cameraStatus.isGranted;
    });
  }

  Future<void> _loadSpeechLocalePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedLocaleId = prefs.getString(_speechLocalePreferenceKey);
      final normalized = (storedLocaleId == null || storedLocaleId.isEmpty)
          ? null
          : storedLocaleId;
      if (!mounted) {
        _preferredSpeechLocaleId = normalized;
        return;
      }
      setState(() {
        _preferredSpeechLocaleId = normalized;
        final resolved = _resolveSpeechLocale(
          _availableSpeechLocales,
          _systemSpeechLocale,
        );
        if (resolved != null) {
          _speechLocaleId = resolved.localeId;
          _speechLocaleLabel = resolved.name;
        }
      });
    } catch (_) {}
  }

  Future<void> _persistSpeechLocalePreference(String? localeId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (localeId == null || localeId.isEmpty) {
        await prefs.remove(_speechLocalePreferenceKey);
        return;
      }
      await prefs.setString(_speechLocalePreferenceKey, localeId);
    } catch (_) {}
  }

  stt.LocaleName? _resolveSpeechLocale(
    List<stt.LocaleName> locales,
    stt.LocaleName? systemLocale,
  ) {
    if (locales.isEmpty) return null;
    final preferredLocaleId = _preferredSpeechLocaleId;
    if (preferredLocaleId != null) {
      for (final locale in locales) {
        if (_sameLocaleId(locale.localeId, preferredLocaleId)) {
          return locale;
        }
      }
    }
    return _bestSpeechLocale(locales, systemLocale);
  }

  Future<void> _initSpeech() async {
    if (_speechReady) {
      if (_availableSpeechLocales.isEmpty) {
        try {
          final locales = await _speech.locales();
          final systemLocale = await _speech.systemLocale();
          var preferredLocaleFound = false;
          final preferredLocaleId = _preferredSpeechLocaleId;
          if (preferredLocaleId != null) {
            preferredLocaleFound = locales.any(
              (locale) => _sameLocaleId(locale.localeId, preferredLocaleId),
            );
          }
          final selectedLocale = _resolveSpeechLocale(locales, systemLocale);
          final shouldClearPreferred =
              !preferredLocaleFound && preferredLocaleId != null;
          if (!mounted) {
            _availableSpeechLocales = locales;
            _systemSpeechLocale = systemLocale;
            if (selectedLocale != null) {
              _speechLocaleId = selectedLocale.localeId;
              _speechLocaleLabel = selectedLocale.name;
            }
            if (shouldClearPreferred) {
              _preferredSpeechLocaleId = null;
              unawaited(_persistSpeechLocalePreference(null));
            }
            return;
          }
          setState(() {
            _availableSpeechLocales = locales;
            _systemSpeechLocale = systemLocale;
            if (selectedLocale != null) {
              _speechLocaleId = selectedLocale.localeId;
              _speechLocaleLabel = selectedLocale.name;
            }
            if (shouldClearPreferred) {
              _preferredSpeechLocaleId = null;
            }
          });
          if (shouldClearPreferred) {
            unawaited(_persistSpeechLocalePreference(null));
          }
        } catch (_) {}
      }
      return;
    }
    final ready = await _speech.initialize(
      finalTimeout: const Duration(seconds: 5),
      onStatus: (status) {
        if (status == stt.SpeechToText.listeningStatus && _isListening) {
          return;
        }
        final shouldRestart =
            status == stt.SpeechToText.doneStatus ||
            status == stt.SpeechToText.notListeningStatus;
        if (shouldRestart &&
            _isListening &&
            !_speech.isListening &&
            !_isSpeechTransitioning) {
          _lastSpeechStopAt = DateTime.now();
          _proactiveRotateTimer?.cancel();
          unawaited(_resumeListening());
        }
      },
      onError: (_) {
        if (_isListening && !_speech.isListening && !_isSpeechTransitioning) {
          _lastSpeechStopAt = DateTime.now();
          unawaited(_resumeListening());
        }
      },
    );

    if (ready) {
      try {
        final locales = await _speech.locales();
        final systemLocale = await _speech.systemLocale();
        var preferredLocaleFound = false;
        final preferredLocaleId = _preferredSpeechLocaleId;
        if (preferredLocaleId != null) {
          preferredLocaleFound = locales.any(
            (locale) => _sameLocaleId(locale.localeId, preferredLocaleId),
          );
        }
        final selectedLocale = _resolveSpeechLocale(locales, systemLocale);
        _availableSpeechLocales = locales;
        _systemSpeechLocale = systemLocale;
        if (!preferredLocaleFound && preferredLocaleId != null) {
          _preferredSpeechLocaleId = null;
          unawaited(_persistSpeechLocalePreference(null));
        }
        if (selectedLocale != null) {
          _speechLocaleId = selectedLocale.localeId;
          _speechLocaleLabel = selectedLocale.name;
        }
      } catch (_) {}
    }

    setState(() {
      _speechReady = ready;
    });
  }

  Future<void> _showSpeechLocalePicker() async {
    if (_isListening) {
      _showInfoMessage('End meeting before changing language');
      return;
    }
    await _initSpeech();
    if (!_speechReady || _availableSpeechLocales.isEmpty) {
      _showInfoMessage('Speech language options are not available yet');
      return;
    }
    if (!mounted) return;

    const autoOptionValue = '__auto__';
    final currentSelection = _preferredSpeechLocaleId ?? autoOptionValue;
    final sortedLocales = [..._availableSpeechLocales]
      ..sort((a, b) => a.name.compareTo(b.name));

    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.8,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose speech language',
                    style: TextStyle(
                      color: softWhite,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView(
                      children: [
                        ListTile(
                          leading: Icon(
                            currentSelection == autoOptionValue
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            color: currentSelection == autoOptionValue
                                ? accentCyan
                                : Colors.white38,
                          ),
                          title: Text(
                            'Auto (System) - $_speechLocaleLabel',
                            style: const TextStyle(color: softWhite),
                          ),
                          onTap: () => Navigator.pop(context, autoOptionValue),
                        ),
                        for (final locale in sortedLocales)
                          ListTile(
                            leading: Icon(
                              currentSelection == locale.localeId
                                  ? Icons.check_circle
                                  : Icons.circle_outlined,
                              color: currentSelection == locale.localeId
                                  ? accentCyan
                                  : Colors.white38,
                            ),
                            title: Text(
                              locale.name,
                              style: const TextStyle(color: softWhite),
                            ),
                            subtitle: Text(
                              locale.localeId,
                              style: const TextStyle(color: Colors.white60),
                            ),
                            onTap: () => Navigator.pop(context, locale.localeId),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (selected == null) return;
    final nextPreferredLocaleId = selected == autoOptionValue ? null : selected;
    await _persistSpeechLocalePreference(nextPreferredLocaleId);
    if (!mounted) return;
    setState(() {
      _preferredSpeechLocaleId = nextPreferredLocaleId;
      final resolved = _resolveSpeechLocale(
        _availableSpeechLocales,
        _systemSpeechLocale,
      );
      if (resolved != null) {
        _speechLocaleId = resolved.localeId;
        _speechLocaleLabel = resolved.name;
      }
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
      final startedAt = DateTime.now();
      _isListening = true;
      _sessionStart = startedAt;
      _activeSessionId = startedAt.microsecondsSinceEpoch.toString();
      _liveTranscript = '';
      _livePartial = '';
      _lastFinalTranscript = '';
      _liveWhiteboardSnapshots.clear();
      _liveWhiteboardOcrByPath.clear();
      _whiteboardStatus = _watchWhiteboardMode
          ? 'Preparing camera for whiteboard snapshots'
          : 'Whiteboard watch is off';
    });
    _startListeningSupervision();
    if (_watchWhiteboardMode) {
      unawaited(_startWhiteboardCapture());
    }

    await _startSpeechRecognition();
  }

  Future<void> _startSpeechRecognition() async {
    if (!_isListening || _speech.isListening || _isSpeechTransitioning) return;
    _isSpeechTransitioning = true;
    var shouldRetry = false;
    try {
      final lastStopAt = _lastSpeechStopAt;
      if (lastStopAt != null) {
        final elapsed = DateTime.now().difference(lastStopAt);
        if (elapsed < _restartCooldownWindow) {
          await Future<void>.delayed(
            _restartCooldownWindow - elapsed,
          );
        }
      }
      if (!_isListening || _speech.isListening) return;
      await _speech.listen(
        onResult: _handleSpeechResult,
        listenFor: _maxListenWindow,
        pauseFor: _silencePauseWindow,
        localeId: _speechLocaleId,
        listenOptions: stt.SpeechListenOptions(
          cancelOnError: false,
          partialResults: true,
          onDevice: false,
          listenMode: stt.ListenMode.dictation,
          autoPunctuation: true,
        ),
      );
    } catch (_) {
      if (_isListening) {
        _lastSpeechStopAt = DateTime.now();
        shouldRetry = true;
      }
    } finally {
      _isSpeechTransitioning = false;
    }
    if (shouldRetry && _isListening) {
      unawaited(_resumeListening());
    }
  }

  Future<void> _resumeListening() async {
    if (!_isListening ||
        _isAutoRestarting ||
        _isRotatingSession ||
        _isSpeechTransitioning ||
        _speech.isListening) {
      return;
    }
    _isAutoRestarting = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 850));
      if (!_isListening ||
          _isRotatingSession ||
          _isSpeechTransitioning ||
          _speech.isListening) {
        return;
      }
      await _startSpeechRecognition();
    } finally {
      _isAutoRestarting = false;
    }
  }

  void _startListeningSupervision() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) {
      if (!_isListening ||
          _speech.isListening ||
          _isAutoRestarting ||
          _isRotatingSession ||
          _isSpeechTransitioning) {
        return;
      }
      unawaited(_resumeListening());
    });
    _scheduleProactiveRotation();
  }

  void _scheduleProactiveRotation() {
    _proactiveRotateTimer?.cancel();
    _proactiveRotateTimer = null;
  }

  Future<void> _stopSpeechRecognition() async {
    var spin = 0;
    while (_isSpeechTransitioning && spin < 10) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      spin += 1;
    }
    if (_isSpeechTransitioning) return;
    _isSpeechTransitioning = true;
    try {
      var stoppedActiveSession = false;
      if (_speech.isListening) {
        await _speech.stop();
        stoppedActiveSession = true;
      }
      _lastSpeechStopAt = DateTime.now();
      if (stoppedActiveSession) {
        // Prevent immediate stop/start churn that can deadlock CoreAudio on iOS.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (_) {
      _lastSpeechStopAt = DateTime.now();
    } finally {
      _isSpeechTransitioning = false;
    }
  }

  void _stopListeningSupervision() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _proactiveRotateTimer?.cancel();
    _proactiveRotateTimer = null;
    _isRotatingSession = false;
    _isAutoRestarting = false;
  }

  void _startNewMeeting() {
    _stopListeningSupervision();
    _stopWhiteboardCapture(disposeCamera: true);
    if (_isListening) {
      _isListening = false;
      unawaited(_stopSpeechRecognition());
    }

    setState(() {
      _showPreviousMeetings = false;
      _sessionStart = null;
      _activeSessionId = null;
      _liveTranscript = '';
      _livePartial = '';
      _lastFinalTranscript = '';
      _liveWhiteboardSnapshots.clear();
      _liveWhiteboardOcrByPath.clear();
      _whiteboardStatus = _watchWhiteboardMode
          ? 'Ready to capture whiteboard snapshots'
          : 'Whiteboard watch is off';
    });
  }

  Future<void> _goToPreviousMeeting() async {
    if (_sessions.isEmpty) {
      _showInfoMessage('No previous meetings yet');
      return;
    }

    setState(() {
      _showPreviousMeetings = true;
    });

    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  void _showInfoMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleSpeechResult(SpeechRecognitionResult result) {
    final text = _normalizeTranscriptLine(result.recognizedWords);
    if (text.isEmpty) return;

    if (!result.finalResult) {
      if (_livePartial == text) return;
      final now = DateTime.now();
      final lastPartialUiUpdateAt = _lastPartialUiUpdateAt;
      if (lastPartialUiUpdateAt != null &&
          now.difference(lastPartialUiUpdateAt) < _partialUiThrottleWindow) {
        return;
      }
      _lastPartialUiUpdateAt = now;
      setState(() {
        _livePartial = text;
      });
      _scheduleLiveTranscriptScroll();
      return;
    }

    _lastPartialUiUpdateAt = null;
    if (_isDuplicateFinalTranscript(text)) {
      if (_livePartial.isNotEmpty) {
        setState(() {
          _livePartial = '';
        });
      }
      return;
    }

    setState(() {
      _livePartial = '';
      _lastFinalTranscript = text;
      _appendToLiveTranscript(text);
    });
    _scheduleLiveTranscriptScroll();
  }

  void _endSession() {
    if (!_isListening) return;
    _stopListeningSupervision();
    _stopWhiteboardCapture(disposeCamera: true);
    unawaited(_stopSpeechRecognition());

    final sessionStart = _sessionStart ?? DateTime.now();
    final transcriptText = _liveTranscriptPreviewText(includePartial: true);
    final transcript = transcriptText.isEmpty
        ? <String>[]
        : <String>[transcriptText];
    final title = _titleFromTranscript(transcriptText);
    final session = SessionEntry(
      id: _activeSessionId ?? sessionStart.microsecondsSinceEpoch.toString(),
      title: title,
      headline: 'Meeting notes',
      summary: 'Processing on backend...',
      timestamp: sessionStart,
      duration: DateTime.now().difference(sessionStart),
      transcript: transcript,
      whiteboardSnapshots: [..._liveWhiteboardSnapshots],
      whiteboardOcrBySnapshot: Map<String, String>.from(
        _liveWhiteboardOcrByPath,
      ),
    );

    setState(() {
      _isListening = false;
      _sessions.insert(0, session);
      _sessionStart = null;
      _activeSessionId = null;
      _liveTranscript = '';
      _livePartial = '';
      _lastFinalTranscript = '';
      _liveWhiteboardSnapshots.clear();
      _liveWhiteboardOcrByPath.clear();
      _whiteboardStatus = _watchWhiteboardMode
          ? 'Ready to capture whiteboard snapshots'
          : 'Whiteboard watch is off';
    });

    _sendToBackend(session);
  }

  Future<void> _sendToBackend(SessionEntry session) async {
    _updateSession(session.id, (entry) {
      entry.processingState = MeetingProcessingState.sending;
      entry.processingMessage = 'Sending transcript to backend';
    });

    try {
      final payload = jsonEncode({
        'session_id': session.id,
        'title': session.title,
        'transcript': session.transcript,
        'duration_seconds': session.duration.inSeconds,
        'whiteboard_snapshot_paths': session.whiteboardSnapshots,
        'whiteboard_snapshot_count': session.whiteboardSnapshots.length,
        'whiteboard_ocr_by_snapshot': session.whiteboardOcrBySnapshot,
        'whiteboard_ocr_text': session.whiteboardOcrBySnapshot.values.join(
          '\n\n',
        ),
      });

      final uri = Uri.parse(_meetingProcessEndpoint);
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await httpClient
            .postUrl(uri)
            .timeout(const Duration(seconds: 10));
        request.headers.set('Content-Type', 'application/json');
        request.add(utf8.encode(payload));
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final Map<String, dynamic> result = {};
          try {
            final decoded = jsonDecode(body);
            if (decoded is Map<String, dynamic>) {
              result.addAll(decoded);
            }
          } catch (_) {}

          final backendSummary = result['summary'];
          final backendHeadline = result['headline'];
          final backendStatus = result['status'];
          final backendState = backendStatus is String
              ? backendStatus.toLowerCase()
              : '';
          final wasProcessed =
              backendState == 'processed' ||
              backendState == 'complete' ||
              backendState == 'completed';
          final failedOnBackend =
              backendState == 'failed' ||
              backendState == 'error' ||
              backendState == 'error_state';

          _updateSession(session.id, (entry) {
            if (failedOnBackend) {
              entry.processingState = MeetingProcessingState.failed;
              entry.processingMessage =
                  'Backend failed to process meeting notes';
            } else {
              entry.processingState = wasProcessed
                  ? MeetingProcessingState.processed
                  : MeetingProcessingState.sent;
              entry.processingMessage = wasProcessed
                  ? 'Processed by backend'
                  : 'Sent to backend';
            }
            if (backendHeadline is String &&
                backendHeadline.trim().isNotEmpty) {
              entry.headline = backendHeadline.trim();
            }
            if (backendSummary is String && backendSummary.trim().isNotEmpty) {
              entry.summary = backendSummary.trim();
            }
          });
        } else {
          throw HttpException('Request failed: ${response.statusCode}');
        }
      } finally {
        httpClient.close(force: true);
      }
    } catch (error) {
      _updateSession(session.id, (entry) {
        entry.processingState = MeetingProcessingState.failed;
        entry.processingMessage = 'Failed to send: ${error.toString()}';
      });
    }
  }

  void _updateSession(String sessionId, void Function(SessionEntry) update) {
    final index = _sessions.indexWhere((session) => session.id == sessionId);
    if (index == -1) return;
    setState(() {
      update(_sessions[index]);
    });
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
              Text(
                _watchWhiteboardMode
                    ? 'Enable microphone, speech + camera'
                    : 'Enable microphone + speech',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: softWhite,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _watchWhiteboardMode
                    ? 'Pulse Meter needs Microphone, Speech Recognition, and Camera '
                          'to transcribe sessions and capture whiteboard snapshots.'
                    : 'Pulse Meter needs access to transcribe meeting notes. '
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

  String _permissionStatus() {
    final audioStatus = _hasPermissions
        ? 'Microphone & speech enabled'
        : 'Microphone or speech access required';
    if (_watchWhiteboardMode) {
      final cameraStatus = _hasCameraPermission
          ? 'camera enabled'
          : 'camera required';
      return '$audioStatus • $cameraStatus • $_speechLocaleLabel';
    }
    if (_hasPermissions) {
      return 'Microphone & speech enabled • $_speechLocaleLabel';
    }
    return 'Microphone or speech access required';
  }

  void _toggleWatchWhiteboard(bool enabled) {
    if (_watchWhiteboardMode == enabled) return;
    setState(() {
      _watchWhiteboardMode = enabled;
      _hasCameraPermission = enabled ? _hasCameraPermission : false;
      _whiteboardStatus = enabled
          ? 'Will capture every 30 seconds when meeting is live'
          : 'Whiteboard watch is off';
    });
    if (enabled) {
      if (_isListening) {
        unawaited(_startWhiteboardCapture());
      }
      return;
    }
    _stopWhiteboardCapture(disposeCamera: true);
  }

  stt.LocaleName? _bestSpeechLocale(
    List<stt.LocaleName> locales,
    stt.LocaleName? systemLocale,
  ) {
    if (locales.isEmpty) return null;

    for (final locale in locales) {
      if (_sameLocaleId(locale.localeId, systemLocale?.localeId)) {
        return locale;
      }
    }

    final systemLanguage = _languageFromLocaleId(systemLocale?.localeId);
    if (systemLanguage != null) {
      for (final locale in locales) {
        if (_languageFromLocaleId(locale.localeId) == systemLanguage) {
          return locale;
        }
      }
    }

    for (final locale in locales) {
      if (_sameLocaleId(locale.localeId, _speechLocaleId)) {
        return locale;
      }
    }

    for (final locale in locales) {
      if (_languageFromLocaleId(locale.localeId) == 'en') {
        return locale;
      }
    }

    return locales.first;
  }

  bool _sameLocaleId(String localeId, String? otherLocaleId) {
    if (otherLocaleId == null || otherLocaleId.isEmpty) return false;
    return localeId.replaceAll('-', '_').toLowerCase() ==
        otherLocaleId.replaceAll('-', '_').toLowerCase();
  }

  String? _languageFromLocaleId(String? localeId) {
    if (localeId == null || localeId.isEmpty) return null;
    final normalized = localeId.replaceAll('-', '_').toLowerCase();
    final separator = normalized.indexOf('_');
    if (separator == -1) return normalized;
    return normalized.substring(0, separator);
  }

  String _normalizeTranscriptLine(String text) {
    return text.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  bool _isDuplicateFinalTranscript(String text) {
    final lowered = text.toLowerCase();
    return _lastFinalTranscript.toLowerCase() == lowered;
  }

  void _appendToLiveTranscript(String text) {
    final normalized = _normalizeTranscriptLine(text);
    if (normalized.isEmpty) return;
    if (_liveTranscript.isEmpty) {
      _liveTranscript = normalized;
      return;
    }
    final endsWithWhitespace = RegExp(r'\s$').hasMatch(_liveTranscript);
    final startsWithPunctuation = RegExp(r'^[,.;:!?)]').hasMatch(normalized);
    final separator = (endsWithWhitespace || startsWithPunctuation) ? '' : ' ';
    _liveTranscript = '$_liveTranscript$separator$normalized';
  }

  String _liveTranscriptPreviewText({required bool includePartial}) {
    final partial = _normalizeTranscriptLine(_livePartial);
    if (!includePartial || partial.isEmpty) {
      return _liveTranscript;
    }
    if (_liveTranscript.isEmpty) {
      return partial;
    }
    final startsWithPunctuation = RegExp(r'^[,.;:!?)]').hasMatch(partial);
    final separator = startsWithPunctuation ? '' : ' ';
    return '$_liveTranscript$separator$partial';
  }

  String _titleFromTranscript(String transcriptText) {
    final normalized = _normalizeTranscriptLine(transcriptText);
    if (normalized.isEmpty) return 'Untitled meeting notes';
    const maxLength = 90;
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength - 3)}...';
  }

  void _scheduleLiveTranscriptScroll() {
    if (_isTranscriptScrollScheduled) return;
    _isTranscriptScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isTranscriptScrollScheduled = false;
      if (!mounted || !_liveTranscriptController.hasClients) return;
      final maxExtent = _liveTranscriptController.position.maxScrollExtent;
      _liveTranscriptController.jumpTo(maxExtent);
    });
  }

  Future<void> _startWhiteboardCapture() async {
    if (!_watchWhiteboardMode || !_isListening) return;
    if (_isPreparingWhiteboardCamera) return;
    _isPreparingWhiteboardCamera = true;
    try {
      if (!await _ensureCameraForWhiteboard()) return;
      _whiteboardSnapshotTimer?.cancel();
      _whiteboardSnapshotTimer = Timer.periodic(_whiteboardSnapshotInterval, (
        _,
      ) {
        unawaited(_captureWhiteboardSnapshot());
      });
      await _captureWhiteboardSnapshot();
      if (!mounted) return;
      setState(() {
        final count = _liveWhiteboardSnapshots.length;
        final ocrCount = _liveWhiteboardOcrByPath.length;
        _whiteboardStatus = count == 0
            ? 'Watching whiteboard (captures every 30 seconds)'
            : 'Watching whiteboard ($count snapshots, $ocrCount OCR results)';
      });
    } finally {
      _isPreparingWhiteboardCamera = false;
    }
  }

  Future<void> _captureWhiteboardSnapshotManually() async {
    if (!_isListening) {
      _showInfoMessage('Start meeting before adding a whiteboard snapshot');
      return;
    }
    if (!await _ensureCameraForWhiteboard()) return;
    await _captureWhiteboardSnapshot(allowWhenWatchModeOff: true);
    if (!mounted || _watchWhiteboardMode) return;
    setState(() {
      final ocrCount = _liveWhiteboardOcrByPath.length;
      _whiteboardStatus =
          'Manual snapshot captured (${_liveWhiteboardSnapshots.length} total, $ocrCount OCR results)';
    });
  }

  Future<bool> _ensureCameraForWhiteboard() async {
    final cameraPermission = await Permission.camera.request();
    if (!cameraPermission.isGranted) {
      if (!mounted) return false;
      setState(() {
        _hasCameraPermission = false;
        _whiteboardStatus = 'Camera permission required for whiteboard watch';
      });
      return false;
    }
    _hasCameraPermission = true;

    if (_whiteboardCamera?.value.isInitialized ?? false) return true;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _whiteboardStatus = 'No camera available on this device';
          });
        }
        return false;
      }

      final selected = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      final previous = _whiteboardCamera;
      _whiteboardCamera = controller;
      if (previous != null) {
        await previous.dispose();
      }
      if (mounted) {
        setState(() {
          _whiteboardStatus = 'Camera ready for whiteboard snapshots';
        });
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _whiteboardStatus = 'Camera unavailable: ${error.toString()}';
        });
      }
      return false;
    }
  }

  Future<void> _captureWhiteboardSnapshot({
    bool allowWhenWatchModeOff = false,
  }) async {
    if (!_isListening) return;
    if (!allowWhenWatchModeOff && !_watchWhiteboardMode) return;
    if (_isCapturingWhiteboardSnapshot) return;
    final camera = _whiteboardCamera;
    if (camera == null || !camera.value.isInitialized) return;

    _isCapturingWhiteboardSnapshot = true;
    try {
      final shot = await camera.takePicture();
      final savedFile = await _persistWhiteboardSnapshot(shot);
      if (savedFile == null || !mounted) return;
      final extractedText = await _extractWhiteboardText(savedFile.path);
      setState(() {
        _liveWhiteboardSnapshots.add(savedFile.path);
        if (extractedText.isNotEmpty) {
          _liveWhiteboardOcrByPath[savedFile.path] = extractedText;
        }
        final ocrCount = _liveWhiteboardOcrByPath.length;
        _whiteboardStatus = _watchWhiteboardMode
            ? 'Watching whiteboard (${_liveWhiteboardSnapshots.length} snapshots, $ocrCount OCR results)'
            : 'Manual snapshot captured (${_liveWhiteboardSnapshots.length} total, $ocrCount OCR results)';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _whiteboardStatus = 'Snapshot failed: ${error.toString()}';
        });
      }
    } finally {
      _isCapturingWhiteboardSnapshot = false;
    }
  }

  Future<String> _extractWhiteboardText(String imagePath) async {
    try {
      final input = InputImage.fromFilePath(imagePath);
      final recognized = await _whiteboardTextRecognizer.processImage(input);
      return recognized.text.trim();
    } catch (_) {
      return '';
    }
  }

  Future<File?> _persistWhiteboardSnapshot(XFile shot) async {
    final root = await getApplicationDocumentsDirectory();
    final sessionId =
        _activeSessionId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final snapshotDir = Directory(
      '${root.path}/whiteboard_snapshots/$sessionId',
    );
    if (!await snapshotDir.exists()) {
      await snapshotDir.create(recursive: true);
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final targetPath = '${snapshotDir.path}/whiteboard_$stamp.jpg';
    await shot.saveTo(targetPath);
    return File(targetPath);
  }

  void _stopWhiteboardCapture({bool disposeCamera = false}) {
    _whiteboardSnapshotTimer?.cancel();
    _whiteboardSnapshotTimer = null;
    _isPreparingWhiteboardCamera = false;
    _isCapturingWhiteboardSnapshot = false;
    if (!disposeCamera) return;
    final camera = _whiteboardCamera;
    _whiteboardCamera = null;
    if (camera != null) {
      unawaited(camera.dispose());
    }
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
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const DrawerHeader(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [midnight, deepIndigo],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    'Pulse Meter',
                    style: TextStyle(
                      color: softWhite,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New meeting'),
                onTap: () {
                  Navigator.pop(context);
                  _startNewMeeting();
                },
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Previous meeting'),
                onTap: () {
                  Navigator.pop(context);
                  _goToPreviousMeeting();
                },
              ),
            ],
          ),
        ),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            'Pulse Meter',
            style: TextStyle(fontWeight: FontWeight.w700, color: softWhite),
          ),
        ),
        body: _showPreviousMeetings
            ? ListView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  _buildHero(),
                  const SizedBox(height: 20),
                  _buildSectionHeader(
                    'Previous meeting notes',
                    key: _previousMeetingsKey,
                  ),
                  const SizedBox(height: 12),
                  if (_sessions.isEmpty) _buildEmptyState(),
                  for (final session in _sessions) _buildSessionCard(session),
                ],
              )
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHero(),
                    const SizedBox(height: 20),
                    Expanded(child: _buildLiveSessionCard()),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildHero() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Text(
          'Capture meeting',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: softWhite,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Pulse Meter listens, transcribes, and sends meeting notes to your backend for processing.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildLiveSessionCard() {
    final liveText = _liveTranscriptPreviewText(includePartial: true);
    final hasPartial = _livePartial.trim().isNotEmpty;
    final finalizedText = _liveTranscript;
    final partialText = hasPartial
        ? _liveTranscriptPreviewText(
            includePartial: true,
          ).substring(finalizedText.length)
        : '';
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactLayout = constraints.maxHeight < 640;
        final transcript = _buildTranscriptSection(
          liveText: liveText,
          finalizedText: finalizedText,
          hasPartial: hasPartial,
          partialText: partialText,
        );
        final controls = [
          _GlassCard(child: _buildLiveStatusSection()),
          const SizedBox(height: 12),
          _GlassCard(child: _buildWhiteboardSection()),
          const SizedBox(height: 12),
          if (compactLayout) SizedBox(height: 220, child: transcript),
          if (!compactLayout) Expanded(child: transcript),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildStartMeetingButton()),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _isListening ? _endSession : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: softWhite,
                    side: const BorderSide(color: Colors.white30),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'End meeting',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
          if (!_hasPermissions)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton(
                onPressed: _ensurePermissions,
                child: Text(
                  _watchWhiteboardMode
                      ? 'Enable microphone, speech + camera'
                      : 'Enable microphone + speech',
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            _permissionStatus(),
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ];
        if (!compactLayout) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: controls,
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: controls,
          ),
        );
      },
    );
  }

  Widget _buildLiveStatusSection() {
    final statusColor = _isListening ? liveGreen : idleAmber;
    return Row(
      children: [
        _LivePulseIndicator(color: statusColor, isActive: _isListening),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isListening ? 'Live pulse is active' : 'Standby',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: softWhite,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _isListening
                    ? 'Listening in $_speechLocaleLabel. Press End meeting when you are done.'
                    : 'Ready in $_speechLocaleLabel. Press Start meeting to begin transcription.',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _isListening
                      ? null
                      : () {
                          unawaited(_showSpeechLocalePicker());
                        },
                  icon: const Icon(Icons.language, size: 16),
                  label: Text(
                    _preferredSpeechLocaleId == null
                        ? 'Language: Auto ($_speechLocaleLabel)'
                        : 'Language: $_speechLocaleLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: softWhite,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: statusColor.withValues(alpha: 0.5)),
          ),
          child: Text(
            _isListening ? 'LIVE' : 'IDLE',
            style: TextStyle(
              color: statusColor,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWhiteboardSection() {
    final helperText = _watchWhiteboardMode
        ? _whiteboardStatus
        : 'Enabling countinous mode makes meeting timelining easier. Good for whiteboard sessions';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accentCyan.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accentCyan.withValues(alpha: 0.45)),
              ),
              child: const Icon(Icons.photo_camera_outlined, color: accentCyan),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Continous mode',
                style: TextStyle(
                  color: softWhite,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Transform.scale(
              scale: 1.15,
              child: Switch(
                value: _watchWhiteboardMode,
                onChanged: _toggleWatchWhiteboard,
                activeThumbColor: Colors.white,
                activeTrackColor: accentCyan.withValues(alpha: 0.85),
                inactiveThumbColor: Colors.white70,
                inactiveTrackColor: Colors.white24,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          helperText,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  unawaited(_captureWhiteboardSnapshotManually());
                },
                style: FilledButton.styleFrom(
                  backgroundColor: accentCyan.withValues(alpha: 0.16),
                  foregroundColor: accentCyan,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: accentCyan.withValues(alpha: 0.45)),
                  ),
                ),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text(
                  'Manual Snap',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${_liveWhiteboardSnapshots.length} snaps\n${_liveWhiteboardOcrByPath.length} OCR',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
              textAlign: TextAlign.right,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTranscriptSection({
    required String liveText,
    required String finalizedText,
    required bool hasPartial,
    required String partialText,
  }) {
    return _GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader('Transcript'),
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: liveText.isEmpty
                  ? const Center(
                      child: Text(
                        'Transcript will appear here as you speak.',
                        style: TextStyle(color: Colors.white60),
                      ),
                    )
                  : ListView(
                      controller: _liveTranscriptController,
                      padding: EdgeInsets.zero,
                      children: [
                        SelectableText.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: finalizedText,
                                style: const TextStyle(
                                  color: softWhite,
                                  fontSize: 14,
                                  height: 1.45,
                                ),
                              ),
                              if (hasPartial)
                                TextSpan(
                                  text: partialText,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                    height: 1.45,
                                  ),
                                ),
                            ],
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

  Widget _buildStartMeetingButton() {
    final canStart = !_isListening;
    final buttonGradient = canStart
        ? const [accentMagenta, accentViolet]
        : const [Colors.white24, Colors.white10];

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: buttonGradient),
        borderRadius: BorderRadius.circular(16),
        boxShadow: canStart
            ? [
                BoxShadow(
                  color: accentMagenta.withValues(alpha: 0.28),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: FilledButton(
        onPressed: canStart ? _startListening : null,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: softWhite,
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: const Text(
          'Start meeting',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {Key? key}) {
    return Text(
      key: key,
      title,
      style: const TextStyle(
        color: softWhite,
        fontSize: 18,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _statusChip(String label, bool isActive, {Color? color}) {
    final chipColor = isActive ? (color ?? accentViolet) : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: isActive ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: chipColor.withValues(alpha: isActive ? 0.45 : 0.25),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isActive ? chipColor : Colors.black54,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
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
        'No meeting notes yet. Start a new meeting to capture your first meeting notes.',
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
            if (session.whiteboardSnapshots.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Whiteboard snapshots: ${session.whiteboardSnapshots.length} • OCR: ${session.whiteboardOcrBySnapshot.length}',
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                _statusChip(
                  'Sent: ${session.isSent ? 'Yes' : 'No'}',
                  session.isSent,
                  color: Colors.green,
                ),
                const SizedBox(width: 8),
                _statusChip(
                  'Processed: ${session.isProcessed ? 'Yes' : 'No'}',
                  session.isProcessed,
                  color: Colors.blueGrey,
                ),
                if (session.processingState ==
                    MeetingProcessingState.failed) ...[
                  const SizedBox(width: 8),
                  _statusChip('Failed', false, color: Colors.red),
                ],
                const Spacer(),
                Text(
                  '${session.timestamp.month}/${session.timestamp.day}/${session.timestamp.year}',
                  style: const TextStyle(color: Colors.black45, fontSize: 12),
                ),
              ],
            ),
            if (session.processingMessage.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                session.processingMessage,
                style: TextStyle(
                  color: session.isProcessed
                      ? Colors.green.shade700
                      : Colors.black54,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
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

  Color _statusColor(bool active, {Color? activeColor}) {
    return active ? (activeColor ?? Colors.green) : Colors.white24;
  }

  Widget _statusChip(String label, bool isActive, {Color? color}) {
    final chipColor = _statusColor(
      isActive,
      activeColor: color ?? Colors.green,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: isActive ? 0.2 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: chipColor.withValues(alpha: isActive ? 0.45 : 0.25),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isActive ? chipColor : Colors.white54,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
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
            'Meeting details',
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
              title: 'Processing status',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _statusChip(
                        'Sent: ${session.isSent ? 'Yes' : 'No'}',
                        session.isSent,
                        color: Colors.green,
                      ),
                      _statusChip(
                        'Processed: ${session.isProcessed ? 'Yes' : 'No'}',
                        session.isProcessed,
                        color: Colors.blueGrey,
                      ),
                    ],
                  ),
                  if (session.processingMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      session.processingMessage,
                      style: TextStyle(
                        color: session.isProcessed
                            ? Colors.green.shade700
                            : Colors.orange.shade300,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _DetailCard(
              title: 'Summary',
              child: Text(
                session.summary,
                style: const TextStyle(color: softWhite),
              ),
            ),
            const SizedBox(height: 16),
            _DetailCard(
              title: 'Whiteboard snapshots',
              child: session.whiteboardSnapshots.isEmpty
                  ? const Text(
                      'No whiteboard snapshots were captured in this meeting.',
                      style: TextStyle(color: Colors.white70),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: session.whiteboardSnapshots.map((path) {
                        final file = File(path);
                        final ocrText =
                            (session.whiteboardOcrBySnapshot[path] ?? '')
                                .trim();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: file.existsSync()
                                    ? Image.file(
                                        file,
                                        height: 150,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                Container(
                                                  padding: const EdgeInsets.all(
                                                    10,
                                                  ),
                                                  color: Colors.white10,
                                                  child: Text(
                                                    path,
                                                    style: const TextStyle(
                                                      color: Colors.white60,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                      )
                                    : Container(
                                        padding: const EdgeInsets.all(10),
                                        color: Colors.white10,
                                        child: Text(
                                          path,
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                ocrText.isEmpty
                                    ? 'No OCR text extracted for this snapshot.'
                                    : ocrText,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
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

class _GlassCard extends StatelessWidget {
  const _GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.16),
                Colors.white.withValues(alpha: 0.06),
              ],
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 20,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LivePulseIndicator extends StatefulWidget {
  const _LivePulseIndicator({required this.color, required this.isActive});

  final Color color;
  final bool isActive;

  @override
  State<_LivePulseIndicator> createState() => _LivePulseIndicatorState();
}

class _LivePulseIndicatorState extends State<_LivePulseIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.isActive) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _LivePulseIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      _controller.repeat();
      return;
    }
    _controller
      ..stop()
      ..value = 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.color,
        boxShadow: [
          BoxShadow(
            color: widget.color.withValues(alpha: 0.65),
            blurRadius: 10,
            spreadRadius: 1.2,
          ),
        ],
      ),
    );

    if (!widget.isActive) {
      return SizedBox(width: 24, height: 24, child: Center(child: dot));
    }

    return SizedBox(
      width: 24,
      height: 24,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final ringScale = 1 + (_controller.value * 1.7);
          final ringOpacity = (1 - _controller.value) * 0.45;
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: ringScale,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: ringOpacity),
                  ),
                ),
              ),
              child!,
            ],
          );
        },
        child: dot,
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
