import 'dart:convert';
import 'dart:io';

final List<Map<String, dynamic>> _receivedMeetingEvents = <Map<String, dynamic>>[];

Future<void> main() async {
  final host = Platform.environment['BACKEND_HOST'] ?? '0.0.0.0';
  final port = int.tryParse(Platform.environment['BACKEND_PORT'] ?? '8080') ?? 8080;

  final server = await HttpServer.bind(host, port);
  stdout.writeln('Pulse backend listening on http://$host:$port');

  await for (final request in server) {
    await _handleRequest(request);
  }
}

Future<void> _handleRequest(HttpRequest request) async {
  final method = request.method.toUpperCase();
  final path = request.uri.path;

  if (method == 'OPTIONS') {
    _addCorsHeaders(request.response);
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }

  if (method == 'GET' && path == '/health') {
    await _writeJson(
      request.response,
      HttpStatus.ok,
      {
        'status': 'ok',
        'service': 'pulse-meter-backend',
        'time': DateTime.now().toUtc().toIso8601String(),
      },
    );
    return;
  }

  if (method == 'GET' && path == '/dashboard') {
    await _writeHtml(request.response, HttpStatus.ok, _dashboardHtml);
    return;
  }

  if (method == 'GET' && path == '/dashboard/data') {
    await _writeJson(
      request.response,
      HttpStatus.ok,
      {
        'status': 'ok',
        'count': _receivedMeetingEvents.length,
        'items': _receivedMeetingEvents,
      },
    );
    return;
  }

  if (method == 'POST' && path == '/v1/meeting-notes/process') {
    stdout.writeln('[${DateTime.now().toIso8601String()}] POST $path');
    await _handleProcessMeetingNotes(request);
    return;
  }

  await _writeJson(
    request.response,
    HttpStatus.notFound,
    {
      'status': 'not_found',
      'message': 'Unknown route: $method $path',
    },
  );
}

Future<void> _handleProcessMeetingNotes(HttpRequest request) async {
  try {
    final rawBody = await utf8.decoder.bind(request).join();
    final decoded = jsonDecode(rawBody);
    if (decoded is! Map<String, dynamic>) {
      await _writeJson(
        request.response,
        HttpStatus.badRequest,
        {
          'status': 'error',
          'message': 'Request body must be a JSON object.',
        },
      );
      return;
    }

    final sessionId = decoded['session_id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString();
    final title = _asNonEmptyString(decoded['title']) ?? 'Meeting notes';
    final transcript = _normalizeTranscript(decoded['transcript']);
    final summary = _summarizeTranscript(transcript);
    final headline = _buildHeadline(title, transcript);
    final processedAt = DateTime.now().toUtc().toIso8601String();

    _recordMeetingEvent(
      sessionId: sessionId,
      title: title,
      transcript: transcript,
      summary: summary,
      processedAt: processedAt,
      durationSeconds: decoded['duration_seconds'],
    );

    await _writeJson(
      request.response,
      HttpStatus.ok,
      {
        'session_id': sessionId,
        'status': 'processed',
        'headline': headline,
        'summary': summary,
        'processed_at': processedAt,
      },
    );
    stdout.writeln('[${DateTime.now().toIso8601String()}] processed session_id=$sessionId transcript_lines=${transcript.length}');
  } catch (error) {
    stderr.writeln('[${DateTime.now().toIso8601String()}] request error: $error');
    await _writeJson(
      request.response,
      HttpStatus.badRequest,
      {
        'status': 'error',
        'message': 'Invalid request payload: $error',
      },
    );
  }
}

List<String> _normalizeTranscript(dynamic transcript) {
  if (transcript is! List) return const [];
  return transcript
      .whereType<String>()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

String _buildHeadline(String title, List<String> transcript) {
  final base = title.trim().isNotEmpty ? title.trim() : (transcript.isNotEmpty ? transcript.first : 'Meeting notes');
  final maxLength = 90;
  return base.length > maxLength ? '${base.substring(0, maxLength - 3)}...' : base;
}

String _summarizeTranscript(List<String> transcript) {
  if (transcript.isEmpty) {
    return 'No transcript lines were received.';
  }

  final keyPoints = transcript.take(4).toList();
  final actionLines = transcript
      .where(
        (line) =>
            line.toLowerCase().contains('action') ||
            line.toLowerCase().contains('todo') ||
            line.toLowerCase().contains('next step') ||
            line.toLowerCase().contains('follow up'),
      )
      .take(3)
      .toList();

  final buffer = StringBuffer();
  buffer.writeln('Meeting notes summary');
  buffer.writeln('');
  buffer.writeln('Key points:');
  for (final point in keyPoints) {
    buffer.writeln('- $point');
  }

  if (actionLines.isNotEmpty) {
    buffer.writeln('');
    buffer.writeln('Action items:');
    for (final action in actionLines) {
      buffer.writeln('- $action');
    }
  }

  return buffer.toString().trimRight();
}

String? _asNonEmptyString(dynamic value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

void _recordMeetingEvent({
  required String sessionId,
  required String title,
  required List<String> transcript,
  required String summary,
  required String processedAt,
  dynamic durationSeconds,
}) {
  final event = <String, dynamic>{
    'received_at': processedAt,
    'session_id': sessionId,
    'title': title,
    'transcript_lines': transcript.length,
    'transcript': transcript,
    'summary': summary,
    'duration_seconds': durationSeconds,
  };
  _receivedMeetingEvents.insert(0, event);
  const maxEvents = 200;
  if (_receivedMeetingEvents.length > maxEvents) {
    _receivedMeetingEvents.removeRange(maxEvents, _receivedMeetingEvents.length);
  }
}

void _addCorsHeaders(HttpResponse response) {
  response.headers
    ..set('Access-Control-Allow-Origin', '*')
    ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    ..set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
}

Future<void> _writeHtml(HttpResponse response, int statusCode, String html) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.html;
  response.write(html);
  await response.close();
}

Future<void> _writeJson(HttpResponse response, int statusCode, Map<String, dynamic> body) async {
  _addCorsHeaders(response);
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

const String _dashboardHtml = r'''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Pulse Backend Dashboard</title>
  <style>
    :root {
      --bg: #0f1220;
      --panel: #171b2e;
      --panel-2: #202743;
      --text: #f2f4ff;
      --muted: #9aa3c7;
      --ok: #55d39a;
      --line: #2f3860;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: linear-gradient(160deg, #0c1020 0%, #151b33 100%);
      color: var(--text);
    }
    .wrap {
      max-width: 980px;
      margin: 0 auto;
      padding: 24px 16px 40px;
    }
    .head {
      display: flex;
      gap: 12px;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 16px;
    }
    .title {
      font-size: 24px;
      font-weight: 800;
      letter-spacing: 0.2px;
    }
    .meta {
      color: var(--muted);
      font-size: 14px;
    }
    .card {
      background: rgba(23, 27, 46, 0.88);
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 14px;
      margin-bottom: 12px;
      box-shadow: 0 8px 20px rgba(0, 0, 0, 0.25);
    }
    .row {
      display: flex;
      gap: 12px;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 8px;
      flex-wrap: wrap;
    }
    .pill {
      border: 1px solid #2d7d5b;
      color: var(--ok);
      background: rgba(85, 211, 154, 0.12);
      border-radius: 999px;
      padding: 4px 10px;
      font-size: 12px;
      font-weight: 700;
    }
    .mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      color: #c7d0f3;
      font-size: 12px;
      word-break: break-all;
    }
    .label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      margin-bottom: 4px;
    }
    .text {
      white-space: pre-wrap;
      font-size: 14px;
      line-height: 1.35;
      color: #dbe2ff;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="head">
      <div>
        <div class="title">Pulse Backend Dashboard</div>
        <div class="meta">Live view of received meeting notes payloads</div>
      </div>
      <div id="status" class="meta">Loading...</div>
    </div>
    <div id="items"></div>
  </div>

  <script>
    const statusEl = document.getElementById('status');
    const itemsEl = document.getElementById('items');

    function escapeHtml(value) {
      return String(value)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    }

    function render(data) {
      statusEl.textContent = `Received ${data.count} meeting note payload${data.count === 1 ? '' : 's'} · ${new Date().toLocaleTimeString()}`;
      if (!data.items || data.items.length === 0) {
        itemsEl.innerHTML = '<div class="card"><div class="meta">No payloads received yet.</div></div>';
        return;
      }

      itemsEl.innerHTML = data.items.map((item) => {
        const transcript = (item.transcript || []).map((line) => `- ${escapeHtml(line)}`).join('\\n');
        return `
          <div class="card">
            <div class="row">
              <div><strong>${escapeHtml(item.title || 'Meeting notes')}</strong></div>
              <div class="pill">Processed</div>
            </div>
            <div class="label">Session ID</div>
            <div class="mono">${escapeHtml(item.session_id || '')}</div>
            <div class="row" style="margin-top:10px">
              <div class="meta">Received: ${escapeHtml(item.received_at || '')}</div>
              <div class="meta">Lines: ${escapeHtml(item.transcript_lines || 0)}</div>
            </div>
            <div class="label">Transcript</div>
            <div class="text">${transcript || '<em>No lines</em>'}</div>
            <div class="label" style="margin-top:10px">Summary</div>
            <div class="text">${escapeHtml(item.summary || '')}</div>
          </div>
        `;
      }).join('');
    }

    async function refresh() {
      try {
        const response = await fetch('/dashboard/data', { cache: 'no-store' });
        const data = await response.json();
        render(data);
      } catch (error) {
        statusEl.textContent = `Dashboard error: ${error}`;
      }
    }

    refresh();
    setInterval(refresh, 2000);
  </script>
</body>
</html>
''';
