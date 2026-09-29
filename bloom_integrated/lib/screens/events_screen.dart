// lib/screens/events_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';
import '../services/database_service.dart';

final _db = Supabase.instance.client;

// ─────────────────────────────────────────────────────────────────────────────
//  JITSI CONFIG — must match the React admin (SeminarsPage.jsx) exactly
// ─────────────────────────────────────────────────────────────────────────────
const String _jitsiDomain = 'meet.bloomgad.xyz';

/// Same logic as the web admin:
///   `bloomgad${seminar.id.replace(/[^a-zA-Z0-9]/g, '').toLowerCase()}`
String _jitsiRoomName(String seminarId) =>
    'bloomgad${seminarId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase()}';

// ─────────────────────────────────────────────────────────────────────────────
//  MEETING TRACKER — global singleton for attendance duration tracking
// ─────────────────────────────────────────────────────────────────────────────
class _MeetingTracker {
  // How attendance time is stored in seminar_attendance_logs:
  //   join_time          → the FIRST time the student joined (never overwritten)
  //   duration_minutes   → total minutes from all FINISHED sessions
  //   session_started_at → when the CURRENT session began (null when not in the call)
  //   leave_time         → the last time the student left
  // Rejoining after a disconnect ADDS to the total instead of resetting it.
  static String?   seminarId;
  static String?   userId;
  static DateTime? sessionStart;
  static int       previousMinutes = 0;

  static bool get isActive => seminarId != null && sessionStart != null;

  static int _minutesBetween(DateTime from, DateTime to) {
    final secs = to.difference(from).inSeconds;
    return secs <= 0 ? 0 : (secs / 60).round();
  }

  /// Opens a new session. Returns an error message, or null on success.
  static Future<String?> begin(String sid, String uid) async {
    final db  = Supabase.instance.client;
    final now = DateTime.now().toUtc();
    try {
      final existing = await db.from('seminar_attendance_logs')
          .select('join_time, duration_minutes, session_started_at')
          .eq('seminar_id', sid).eq('user_id', uid)
          .maybeSingle();

      int prev = 0;
      if (existing == null) {
        await db.from('seminar_attendance_logs').insert({
          'seminar_id':         sid,
          'user_id':            uid,
          'join_time':          now.toIso8601String(),
          'leave_time':         null,
          'duration_minutes':   0,
          'session_started_at': now.toIso8601String(),
          'attendance_status':  'joined',
          'is_eligible':        false,
        });
      } else {
        prev = (existing['duration_minutes'] as num?)?.toInt() ?? 0;
        // A previous session that was never closed (e.g. the app was closed
        // while in the call): count it up to now so that time isn't lost.
        final openRaw = existing['session_started_at'] as String?;
        if (openRaw != null) {
          final openStart = DateTime.tryParse(openRaw)?.toUtc();
          if (openStart != null) prev += _minutesBetween(openStart, now);
        }
        await db.from('seminar_attendance_logs').update({
          'leave_time':         null,
          'duration_minutes':   prev,
          'session_started_at': now.toIso8601String(),
          // join_time, attendance_status and is_eligible are left untouched
        }).eq('seminar_id', sid).eq('user_id', uid);
      }

      seminarId       = sid;
      userId          = uid;
      sessionStart    = now;
      previousMinutes = prev;
      return null;
    } catch (e) {
      debugPrint('Attendance begin error: $e');
      return e.toString();
    }
  }

  /// Closes the current session and returns the student's TOTAL minutes.
  static Future<int> stop() async {
    if (seminarId == null || userId == null || sessionStart == null) return 0;
    final db   = Supabase.instance.client;
    final now  = DateTime.now().toUtc();
    final sid  = seminarId!;
    final uid  = userId!;
    final total = previousMinutes + _minutesBetween(sessionStart!, now);
    seminarId = null; userId = null; sessionStart = null; previousMinutes = 0;

    try {
      // Only close the session if it is still open. If the admin already ended
      // the meeting, they closed it with the correct end time — don't overwrite.
      final updated = await db.from('seminar_attendance_logs').update({
        'leave_time':         now.toIso8601String(),
        'duration_minutes':   total,
        'session_started_at': null,
      }).eq('seminar_id', sid).eq('user_id', uid)
        .not('session_started_at', 'is', null)
        .select('duration_minutes');

      if ((updated as List).isNotEmpty) return total;

      // Already closed by the admin → report what was saved
      final row = await db.from('seminar_attendance_logs')
          .select('duration_minutes')
          .eq('seminar_id', sid).eq('user_id', uid).maybeSingle();
      return (row?['duration_minutes'] as num?)?.toInt() ?? total;
    } catch (e) {
      debugPrint('Stop attendance error: $e');
      return total;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHARED REGISTRATION STATE
// ─────────────────────────────────────────────────────────────────────────────
class SeminarRegistrationState extends ChangeNotifier {
  Set<String> _registeredIds = {};
  bool _loaded = false;

  Set<String> get registeredIds => _registeredIds;
  bool get loaded => _loaded;
  bool isRegistered(String seminarId) => _registeredIds.contains(seminarId);

  Future<void> load() async {
    _registeredIds = await DatabaseService.fetchMyRegisteredSeminarIds();
    _loaded = true;
    notifyListeners();
  }

  void add(String seminarId) {
    _registeredIds = {..._registeredIds, seminarId};
    notifyListeners();
  }

  void remove(String seminarId) {
    _registeredIds = _registeredIds.where((id) => id != seminarId).toSet();
    notifyListeners();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HELPERS
// ─────────────────────────────────────────────────────────────────────────────
int _extractRegCount(Map<String, dynamic> sem) {
  final list = sem['seminar_registrations'] as List?;
  if (list == null || list.isEmpty) return 0;
  final first = list.first;
  if (first is Map) {
    final val = first['count'];
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val) ?? 0;
  }
  return 0;
}

String _effectiveStatus(Map<String, dynamic> sem) {
  final dbStatus = sem['status'] as String? ?? 'upcoming';
  if (dbStatus == 'cancelled' || dbStatus == 'completed') return dbStatus;
  // If the admin has started the meeting, it stays live until they end it,
  // even if the scheduled end time has passed.
  if (dbStatus == 'ongoing') return 'ongoing';
  final end   = sem['scheduled_end']   as String?;
  final start = sem['scheduled_start'] as String?;
  if (end != null) {
    try {
      final utcEnd = end.endsWith('Z') || end.contains('+') ? end : '${end}Z';
      if (DateTime.now().isAfter(DateTime.parse(utcEnd))) return 'completed';
    } catch (_) {}
  }
  if (start != null) {
    try {
      final utcStart = start.endsWith('Z') || start.contains('+') ? start : '${start}Z';
      if (DateTime.now().isAfter(DateTime.parse(utcStart))) return 'ongoing';
    } catch (_) {}
  }
  return dbStatus;
}

bool _registrationOpen(Map<String, dynamic> sem) {
  final status = sem['status'] as String? ?? 'upcoming';
  if (status == 'cancelled' || status == 'completed') return false;
  final start = sem['scheduled_start'] as String?;
  if (start == null) return true;
  try {
    final utcStart = start.endsWith('Z') || start.contains('+') ? start : '${start}Z';
    return DateTime.now().isBefore(DateTime.parse(utcStart));
  } catch (_) { return true; }
}

bool _seminarHasEnded(Map<String, dynamic> sem) {
  final dbStatus = sem['status'] as String? ?? 'upcoming';
  if (dbStatus == 'cancelled' || dbStatus == 'completed') return true;
  // A meeting the admin has started is never "ended" until they close it.
  if (dbStatus == 'ongoing') return false;
  final raw = (sem['scheduled_end'] ?? sem['scheduled_start']) as String?;
  if (raw == null) return false;
  try {
    final utc = raw.endsWith('Z') || raw.contains('+') ? raw : '${raw}Z';
    return DateTime.now().toUtc().isAfter(DateTime.parse(utc).toUtc());
  } catch (_) { return false; }
}

String _fmtDate(String? iso) {
  if (iso == null) return '—';
  try {
    final utc = iso.endsWith('Z') || iso.contains('+') ? iso : '${iso}Z';
    final d   = DateTime.parse(utc).toLocal();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h  = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m  = d.minute.toString().padLeft(2, '0');
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '${months[d.month - 1]} ${d.day}, ${d.year} · $h:$m $ap';
  } catch (_) { return iso; }
}

String _fmtDateShort(String? iso) {
  if (iso == null) return '—';
  try {
    final d = DateTime.parse(iso).toLocal();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  } catch (_) { return iso; }
}

Map<String, dynamic> _seminarToCalendarEvent(Map<String, dynamic> sem) {
  String? dateOnly(String? iso) {
    if (iso == null) return null;
    try {
      final utc = iso.endsWith('Z') || iso.contains('+') ? iso : '${iso}Z';
      return DateTime.parse(utc).toLocal().toIso8601String().substring(0, 10);
    } catch (_) { return null; }
  }
  return {
    'id':          'seminar_${sem['id']}',
    'title':       sem['title'],
    'description': sem['description'],
    'start_date':  dateOnly(sem['scheduled_start'] as String?),
    'end_date':    dateOnly(sem['scheduled_end'] as String?) ?? dateOnly(sem['scheduled_start'] as String?),
    'color_hex':   '#2563EB',
    'event_type':  'seminar',
    '_source':     'seminar',
    '_raw':        sem,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  JOIN JITSI MEETING — opens in browser (works on all devices immediately)
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _joinJitsiMeeting(
  BuildContext context,
  Map<String, dynamic> seminar, {
  required bool isRegistered,
}) async {
  if (!isRegistered) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('You must be registered for this seminar to join the meeting.',
            style: GoogleFonts.nunito()),
        backgroundColor: AppColors.danger,
        duration: const Duration(seconds: 4)));
    }
    return;
  }

  // Refresh from the database so we never act on a stale list
  // (e.g. the admin just clicked "Start Meeting" and realtime hasn't arrived).
  try {
    final fresh = await Supabase.instance.client
        .from('seminars')
        .select('status, scheduled_start, scheduled_end')
        .eq('id', seminar['id'])
        .maybeSingle();
    if (fresh != null) seminar = {...seminar, ...fresh};
  } catch (e) {
    debugPrint('Could not refresh seminar status: $e');
  }

  if (_seminarHasEnded(seminar)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('This seminar has already ended and is no longer available to join.',
            style: GoogleFonts.nunito()),
        backgroundColor: AppColors.danger,
        duration: const Duration(seconds: 4)));
    }
    return;
  }

  final seminarType = seminar['seminar_type'] as String? ?? 'webinar';
  if (seminarType == 'in_person') {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('This is an in-person seminar. Please attend at the venue.',
            style: GoogleFonts.nunito()),
        backgroundColor: AppColors.primary));
    }
    return;
  }

  final status = seminar['status'] as String? ?? 'upcoming';
  if (status != 'ongoing') {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'The meeting has not started yet. Please wait for the administrator to start it.',
          style: GoogleFonts.nunito()),
        backgroundColor: AppColors.primary,
        duration: const Duration(seconds: 4)));
    }
    return;
  }

  // 1. Build the room name exactly like the React web admin
  final rawId    = (seminar['id'] ?? seminar['seminar_id'])?.toString() ?? '';
  final roomName = _jitsiRoomName(rawId);

  final user    = Supabase.instance.client.auth.currentUser;
  final profile = await Supabase.instance.client
      .from('profiles')
      .select('full_name')
      .eq('id', user?.id ?? '')
      .maybeSingle();

  final rawName = (profile?['full_name'] as String?)?.trim().isNotEmpty == true
      ? (profile!['full_name'] as String).trim()
      : user?.email ?? 'Student';

  // Jitsi parses hash params as JSON, so the string value must be wrapped in
  // quotes (%22). Strip any double quotes in the name so the JSON stays valid.
  final encodedName = Uri.encodeComponent(rawName.replaceAll('"', ''));

  // 2. Build the Jitsi URL — note the $ interpolation on roomName/encodedName
  final jitsiUrl = Uri.parse(
    'https://$_jitsiDomain/$roomName'
    '#userInfo.displayName=%22$encodedName%22'
    '&config.disableDeepLinking=true',
  );
  debugPrint('[Jitsi] Joining room: $jitsiUrl');

  try {
    // 3. Start (or resume) this student's attendance session.
    //    Rejoining after a disconnect keeps the minutes already attended.
    if (user == null) throw Exception('Please sign in again.');
    if (_MeetingTracker.isActive) await _MeetingTracker.stop();
    final beginErr = await _MeetingTracker.begin(rawId, user.id);
    if (beginErr != null) throw Exception('Could not record attendance: $beginErr');

    // 4. Open the meeting in the external browser
    final launched = await launchUrl(
      jitsiUrl,
      mode: LaunchMode.externalApplication,
    );

    if (!launched) {
      await _MeetingTracker.stop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open the meeting. Please try again.',
              style: GoogleFonts.nunito()),
          backgroundColor: AppColors.danger));
      }
      return;
    }
    // No auto-stop timer here: attendance ends when the user returns to the
    // app (see didChangeAppLifecycleState) or when the admin ends the meeting.
  } catch (e) {
    await _MeetingTracker.stop();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not open meeting: ${e.toString()}',
            style: GoogleFonts.nunito()),
        backgroundColor: AppColors.danger));
    }
  }
}


// ─────────────────────────────────────────────────────────────────────────────
//  EVENTS SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class EventsScreen extends StatefulWidget {
  final int initialTab;
  const EventsScreen({super.key, this.initialTab = 0});
  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _regState = SeminarRegistrationState();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
    _tabs.addListener(() { if (mounted) setState(() {}); });
    _regState.load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _regState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F9F0),
      body: Column(children: [
        _header(),
        Expanded(child: TabBarView(controller: _tabs, children: [
          _SeminarsTab(regState: _regState),
          _CalendarTab(regState: _regState),
        ])),
      ]),
    );
  }

  Widget _header() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [AppColors.primaryDark, AppColors.primary]),
      ),
      child: SafeArea(bottom: false, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Events & Seminars', style: GoogleFonts.nunito(
                  color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text('Register, join live, and evaluate', style: GoogleFonts.nunito(
                  color: Colors.white.withValues(alpha: 0.75), fontSize: 13, fontWeight: FontWeight.w500)),
            ]),
          ),
          const SizedBox(height: 14),
          Row(children: [
            _tabButton('Seminars', Icons.school_rounded, 0),
            _tabButton('Calendar', Icons.calendar_month_rounded, 1),
          ]),
        ],
      )),
    );
  }

  Widget _tabButton(String label, IconData icon, int index) {
    final active = _tabs.index == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _tabs.animateTo(index),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(
              color: active ? Colors.white : Colors.transparent, width: 3))),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 16,
                color: active ? Colors.white : Colors.white.withValues(alpha: 0.55)),
            const SizedBox(width: 6),
            Text(label, style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w700,
                color: active ? Colors.white : Colors.white.withValues(alpha: 0.55))),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SEMINARS TAB
// ─────────────────────────────────────────────────────────────────────────────
class _SeminarsTab extends StatefulWidget {
  final SeminarRegistrationState regState;
  const _SeminarsTab({required this.regState});
  @override
  State<_SeminarsTab> createState() => _SeminarsTabState();
}

class _SeminarsTabState extends State<_SeminarsTab> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _seminars   = [];
  bool _loading     = true;
  bool _loadingMore = false;
  bool _hasMore     = true;
  int  _page        = 0;
  String _filter    = 'All';
  final Set<String> _registering  = {};
  final Set<String> _evaluatedIds = {}; // seminar IDs already evaluated by user

  // True once the app has actually gone to the background after joining,
  // so we only stop attendance when the user comes BACK from the meeting.
  bool _leftForMeeting = false;

  static const int  _pageSize    = 10;
  static const List<String> _filters = ['All', 'Live', 'Upcoming', 'Registered', 'Past'];
  final _scrollController = ScrollController();
  Timer? _statusTimer;
  RealtimeChannel? _regChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _scrollController.addListener(_onScroll);
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) { if (mounted) setState(() {}); });
    widget.regState.addListener(_onRegStateChanged);
    _subscribeToRegistrationChanges();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _statusTimer?.cancel();
    widget.regState.removeListener(_onRegStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    _MeetingTracker.stop();
    _regChannel?.unsubscribe();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!_MeetingTracker.isActive) return;

    // Opening the browser sends the app to the background.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _leftForMeeting = true;
      return;
    }

    // Only finalize attendance when the user actually comes back to the app.
    if (state == AppLifecycleState.resumed && _leftForMeeting) {
      _leftForMeeting = false;
      _MeetingTracker.stop().then((durationMins) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            durationMins >= 1
                ? 'Attendance saved. Total time in this seminar: $durationMins minute${durationMins == 1 ? '' : 's'}.'
                : 'Attendance recorded.',
            style: GoogleFonts.nunito()),
          backgroundColor: AppColors.primary,
          duration: const Duration(seconds: 4)));
        // Pick up the latest status (e.g. the admin ended the meeting → Evaluate)
        _load();
      });
    }
  }

  void _subscribeToRegistrationChanges() {
    // Also subscribe to seminar status changes so Join Meeting button
    // activates automatically when admin starts the meeting
    _regChannel = _db
        .channel('seminar_and_registration_changes')
        .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'seminars',
            callback: (payload) {
              // Update status in local list without full reload
              final updated = payload.newRecord;
              final id      = updated['id']?.toString();
              if (id == null) return;
              if (mounted) {
                setState(() {
                  _seminars = _seminars.map((s) =>
                      s['id'].toString() == id ? {...s, ...updated} : s).toList();
                });
              }
            })
        .onPostgresChanges(event: PostgresChangeEvent.insert, schema: 'public',
            table: 'seminar_registrations', callback: (_) => _refreshCounts())
        .onPostgresChanges(event: PostgresChangeEvent.delete, schema: 'public',
            table: 'seminar_registrations', callback: (_) => _refreshCounts())
        .subscribe((status, [error]) =>
            debugPrint('Realtime: $status ${error ?? ''}'));
  }

  Future<void> _refreshCounts() async {
    if (!mounted || _seminars.isEmpty) return;
    try {
      final ids = _seminars.map((s) => s['id'] as String).toList();
      final map = <String, int>{};
      for (final id in ids) {
        final res = await _db.from('seminar_registrations').select('id')
            .eq('seminar_id', id).eq('status', 'registered').count(CountOption.exact);
        map[id] = res.count;
      }
      if (!mounted) return;
      setState(() {
        _seminars = _seminars.map((sem) {
          final id = sem['id'] as String;
          if (!map.containsKey(id)) return sem;
          return {...sem, 'seminar_registrations': [{'count': map[id]!}]};
        }).toList();
      });
    } catch (_) {}
  }

  void _onRegStateChanged() { if (mounted) setState(() {}); }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_loadingMore && _hasMore && _filter == 'All') {
      _loadMore();
    }
  }

  Future<void> _load() async {
    // Fallback: finalize any active meeting tracker when load is called
    if (_MeetingTracker.isActive) {
      _leftForMeeting = false;
      await _MeetingTracker.stop();
    }
    if (!mounted) return;
    setState(() { _loading = true; _page = 0; _hasMore = true; });
    try {
      final sems = await _db.from('seminars').select('*').eq('is_public', true)
          .order('scheduled_start').range(0, _pageSize - 1);
      await widget.regState.load();
      // Load which seminars the user has already evaluated
      final userId = _db.auth.currentUser?.id;
      if (userId != null) {
        final evals = await _db.from('seminar_evaluations')
            .select('seminar_id').eq('user_id', userId).not('submitted_at', 'is', null);
        final ids = Set<String>.from(
            (evals as List).map((e) => e['seminar_id'].toString()));
        if (mounted) setState(() => _evaluatedIds.addAll(ids));
      }
      final list = List<Map<String, dynamic>>.from(sems);
      if (mounted) {
        setState(() { _seminars = list; _hasMore = list.length == _pageSize; _loading = false; });
        await _refreshCounts();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final nextPage = _page + 1;
      final from = nextPage * _pageSize;
      final sems = await _db.from('seminars').select('*').eq('is_public', true)
          .order('scheduled_start').range(from, from + _pageSize - 1);
      final list = List<Map<String, dynamic>>.from(sems);
      if (mounted) {
        setState(() { _seminars.addAll(list); _page = nextPage; _hasMore = list.length == _pageSize; _loadingMore = false; });
        await _refreshCounts();
      }
    } catch (_) { if (mounted) setState(() => _loadingMore = false); }
  }

  List<Map<String, dynamic>> get _liveNow =>
      _seminars.where((s) => _effectiveStatus(s) == 'ongoing').toList();

  Map<String, dynamic>? get _nextRegistered {
    for (final s in _seminars) {
      if (_effectiveStatus(s) == 'upcoming' &&
          widget.regState.isRegistered(s['id'] as String)) {
        return s;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> get _filtered {
    switch (_filter) {
      case 'Live':       return _seminars.where((s) => _effectiveStatus(s) == 'ongoing').toList();
      case 'Upcoming':   return _seminars.where((s) => _effectiveStatus(s) == 'upcoming').toList();
      case 'Registered': return _seminars.where((s) =>
          widget.regState.isRegistered(s['id'] as String) &&
          _effectiveStatus(s) != 'completed' && _effectiveStatus(s) != 'cancelled').toList();
      case 'Past':       return _seminars.where((s) =>
          _effectiveStatus(s) == 'completed' || _effectiveStatus(s) == 'cancelled').toList();
      default:           return _seminars;
    }
  }

  void _optimisticCountUpdate(String semId, {required bool increment}) {
    setState(() {
      _seminars = _seminars.map((sem) {
        if (sem['id'] != semId) return sem;
        final current = _extractRegCount(sem);
        final updated = (increment ? current + 1 : current - 1).clamp(0, 999999);
        return {...sem, 'seminar_registrations': [{'count': updated}]};
      }).toList();
    });
  }

  Future<void> _register(Map<String, dynamic> sem) async {
    final semId  = sem['id'] as String;
    if (_registering.contains(semId)) return;
    await _refreshCounts();
    if (!mounted) return;
    final freshSem = _seminars.firstWhere((s) => s['id'] == semId, orElse: () => sem);
    final isReg    = widget.regState.isRegistered(semId);
    if (!isReg) {
      final regCount = _extractRegCount(freshSem);
      final maxP     = freshSem['max_participants'] as int?;
      if (maxP != null && regCount >= maxP) {
        _showSnack('This seminar is already full.', isError: true); return;
      }
    }
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(isReg ? 'Cancel Registration?' : 'Register for Seminar?',
          style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
      content: Text(isReg
          ? 'Cancel registration for "${freshSem['title']}"?'
          : 'Register for "${freshSem['title']}"?',
          style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[700], height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: GoogleFonts.nunito(color: AppColors.textMid))),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: isReg ? AppColors.danger : AppColors.primaryDark,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), elevation: 0),
            child: Text(isReg ? 'Cancel Registration' : 'Register',
                style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w700))),
      ],
    ));
    if (confirmed != true || !mounted) return;
    setState(() => _registering.add(semId));
    if (isReg) _optimisticCountUpdate(semId, increment: false);
    try {
      if (isReg) {
        final err = await DatabaseService.cancelRegistration(semId);
        if (err != null && mounted) {
          _optimisticCountUpdate(semId, increment: true);
          _showSnack('Failed to cancel. Please try again.', isError: true); return;
        }
        widget.regState.remove(semId);
        _showSnack('Registration cancelled.');
      } else {
        final err = await DatabaseService.registerForSeminar(semId);
        switch (err) {
          case null: widget.regState.add(semId); _showSnack('Successfully registered!'); break;
          case 'already_registered': widget.regState.add(semId); _showSnack('Already registered.'); break;
          case 'seminar_full': _showSnack('Seminar is full.', isError: true); break;
          case 'registration_closed': _showSnack('Registration is closed.', isError: true); break;
          default: _showSnack('Registration failed. Please try again.', isError: true);
        }
      }
      await Future.wait([_refreshCounts(), widget.regState.load()]);
    } finally { if (mounted) setState(() => _registering.remove(semId)); }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.nunito()),
      backgroundColor: isError ? AppColors.danger : AppColors.primary));
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'ongoing':   return const Color(0xFF16A34A);
      case 'completed': return const Color(0xFF2563EB);
      case 'cancelled': return const Color(0xFFDC2626);
      default:          return const Color(0xFFF59E0B);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    final live    = _liveNow;
    final nextReg = _filter == 'All' ? _nextRegistered : null;
    final list    = _filtered;

    // Pre-count extra items before the actual seminar list
    int extraItems = 1; // filter chips always shown
    if (live.isNotEmpty && _filter != 'Past') extraItems++;
    if (nextReg != null) extraItems++;

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: extraItems + (list.isEmpty ? 1 : list.length) +
            (_loadingMore ? 1 : 0) +
            (!_hasMore && _seminars.isNotEmpty && _filter == 'All' ? 1 : 0),
        itemBuilder: (ctx, rawIndex) {
          int i = rawIndex;

          // ── Live banner ──────────────────────────────────────────────
          if (live.isNotEmpty && _filter != 'Past') {
            if (i == 0) {
              return Padding(padding: const EdgeInsets.only(bottom: 14),
                child: _HappeningNowBanner(
                  seminar: live.first, regCount: _extractRegCount(live.first),
                  onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) =>
                    SeminarDetailScreen(seminar: live.first, regState: widget.regState,
                        onRegister: () => _register(live.first)))).then((_) => _load())));
            }
            i--;
          }

          // ── Filter chips ─────────────────────────────────────────────
          if (i == 0) {
            return Padding(padding: const EdgeInsets.only(bottom: 14),
              child: _filterChips(live.length));
          }
          i--;

          // ── Your next seminar ─────────────────────────────────────────
          if (nextReg != null) {
            if (i == 0) {
              return Padding(padding: const EdgeInsets.only(bottom: 14),
                child: _NextSeminarHighlight(seminar: nextReg,
                    onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) =>
                      SeminarDetailScreen(seminar: nextReg, regState: widget.regState,
                          onRegister: () => _register(nextReg)))).then((_) => _load())));
            }
            i--;
          }

          // ── Empty state ───────────────────────────────────────────────
          if (list.isEmpty) {
            if (i == 0) {
              return const _EmptyState(
                icon: Icons.event_busy_rounded, title: 'Nothing here yet',
                sub: 'Try a different filter or check back later');
            }
            return const SizedBox.shrink();
          }

          // ── Loading / end ─────────────────────────────────────────────
          if (i == list.length) {
            if (_loadingMore) {
              return const Padding(padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2)));
            }
            if (!_hasMore && _filter == 'All') {
              return Padding(padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('All ${_seminars.length} seminars loaded',
                    style: GoogleFonts.nunito(fontSize: 12, color: AppColors.textLight))));
            }
          }
          if (i >= list.length) return const SizedBox.shrink();

          // ── Seminar card ──────────────────────────────────────────────
          final sem      = list[i];
          final semId    = sem['id'] as String;
          final isReg    = widget.regState.isRegistered(semId);
          final isBusy   = _registering.contains(semId);
          final regCount = _extractRegCount(sem);
          final status   = _effectiveStatus(sem);
          final maxP     = sem['max_participants'] as int?;
          final isFull   = maxP != null && regCount >= maxP && !isReg;
          final semType  = sem['seminar_type'] as String? ?? 'webinar';
          final hasLink  = semType != 'in_person' && status == 'ongoing'; // Only show join when meeting is live
          final hasEnded = _seminarHasEnded(sem);
          final isOpen   = _registrationOpen(sem);

          String btnLabel;
          final hasEvaluated = _evaluatedIds.contains(sem['id'].toString());
          if (isBusy) {
            btnLabel = isReg ? 'Cancelling…' : 'Registering…';
          } else if (status == 'completed' && isReg && hasEvaluated) {
            btnLabel = 'Evaluated ✓';
          } else if (status == 'completed') {
            btnLabel = isReg ? 'Evaluate' : 'Not Registered';
          } else if (status == 'cancelled') {
            btnLabel = 'Cancelled';
          } else if (isFull) {
            btnLabel = 'Fully Booked';
          } else if (!isOpen && !isReg) {
            btnLabel = 'Closed';
          } else if (isReg) {
            btnLabel = 'Registered';
          } else {
            btnLabel = 'Register';
          }

          VoidCallback? btnAction;
          if (!isBusy && !isFull && !hasEvaluated) {
            if (status == 'completed' && isReg) {
              btnAction = () => Navigator.push(ctx, MaterialPageRoute(builder: (_) =>
                  SeminarDetailScreen(seminar: sem, regState: widget.regState,
                      onRegister: () => _register(sem)))).then((_) {
                // Refresh evaluated IDs in case user just submitted an evaluation
                final userId = _db.auth.currentUser?.id;
                if (userId != null) {
                  _db.from('seminar_evaluations').select('seminar_id')
                      .eq('user_id', userId).not('submitted_at', 'is', null)
                      .then((evals) {
                        if (mounted) {
                          setState(() {
                            _evaluatedIds.addAll((evals as List).map((e) => e['seminar_id'].toString()));
                          });
                        }
                      });
                }
                _load();
              });
            } else if (status != 'cancelled' && status != 'completed' && (isReg || isOpen)) {
              btnAction = () => _register(sem);
            }
          }

          return GestureDetector(
            onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) =>
                SeminarDetailScreen(seminar: sem, regState: widget.regState,
                    onRegister: () => _register(sem)))).then((_) => _load()),
            child: Container(
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: status == 'ongoing' ? const Color(0xFF16A34A) : Colors.transparent, width: 1.5),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))]),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                sem['cover_image_url'] != null
                    ? ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                        child: Image.network(sem['cover_image_url'], height: 140, width: double.infinity,
                            fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()))
                    : Container(height: 6, decoration: const BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                            colors: [AppColors.primaryDark, AppColors.primary]),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(16)))),
                Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(sem['title'] ?? '', style: GoogleFonts.nunito(
                        fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.primaryDark))),
                    const SizedBox(width: 8),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: _statusColor(status).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                        child: Text(status.toUpperCase(), style: GoogleFonts.nunito(
                            fontSize: 10, fontWeight: FontWeight.w800, color: _statusColor(status)))),
                  ]),
                  const SizedBox(height: 8),
                  if (sem['description'] != null) ...[
                    Text(sem['description'], maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[600])),
                    const SizedBox(height: 8),
                  ],
                  _InfoRow(icon: Icons.calendar_today_outlined, text: _fmtDate(sem['scheduled_start'] as String?)),
                  if (sem['scheduled_end'] != null) _InfoRow(icon: Icons.flag_outlined, text: 'Ends ${_fmtDate(sem['scheduled_end'] as String?)}'),
                  if (sem['venue'] != null) _InfoRow(icon: Icons.location_on_outlined, text: sem['venue']),
                  if (hasLink) _InfoRow(icon: Icons.videocam_outlined, text: '${sem['webinar_platform'] ?? 'Online'} Meeting'),
                  _InfoRow(icon: Icons.group_outlined, text: '$regCount registered${maxP != null ? ' / $maxP max' : ''}'),
                  const SizedBox(height: 12),
                  Row(children: [
                    if (hasLink) ...[
                      Expanded(child: OutlinedButton.icon(
                        onPressed: (!hasEnded && isReg) ? () => _joinJitsiMeeting(context, sem, isRegistered: isReg) : null,
                        icon: Icon(hasEnded ? Icons.link_off_rounded : (!isReg ? Icons.lock_outline : Icons.open_in_new), size: 16),
                        label: Text(
                            hasEnded ? 'Ended' : !isReg ? 'Not Registered' : status == 'ongoing' ? 'Join Meeting' : 'Not Started',
                            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: (hasEnded || !isReg) ? Colors.grey[400] : AppColors.primary,
                            side: BorderSide(color: (hasEnded || !isReg) ? Colors.grey[300]! : AppColors.primary),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      )),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: ElevatedButton.icon(
                      onPressed: btnAction,
                      icon: isBusy
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Icon(status == 'completed' ? (isReg ? Icons.star_outline_rounded : Icons.lock_outline)
                              : isFull ? Icons.block_outlined : isReg ? Icons.check_circle_outline : Icons.how_to_reg_outlined, size: 16),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: status == 'completed' ? (isReg ? const Color(0xFFF59E0B) : Colors.grey[300])
                              : isFull ? const Color(0xFFFF6B35) : isReg ? Colors.grey[200]
                              : (!isOpen && !isReg) ? Colors.grey[300] : AppColors.primary,
                          foregroundColor: status == 'completed' ? (isReg ? Colors.white : Colors.grey[500])
                              : isFull ? Colors.white : isReg ? Colors.grey[700]
                              : (!isOpen && !isReg) ? Colors.grey[600] : Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10)),
                      label: Text(btnLabel, style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 13)),
                    )),
                  ]),
                ])),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _filterChips(int liveCount) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: _filters.map((f) {
        final active = _filter == f;
        return Padding(padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => setState(() => _filter = f),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                  color: active ? AppColors.primary : Colors.white,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: active ? AppColors.primary : AppColors.border, width: 1.5)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (f == 'Live') ...[
                  Container(width: 6, height: 6,
                      decoration: BoxDecoration(color: active ? Colors.white : const Color(0xFF16A34A), shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                ],
                Text(f == 'Live' && liveCount > 0 ? 'Live ($liveCount)' : f,
                    style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w700,
                        color: active ? Colors.white : AppColors.textMid)),
              ]),
            ),
          ));
      }).toList()),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  HAPPENING NOW BANNER
// ─────────────────────────────────────────────────────────────────────────────
class _HappeningNowBanner extends StatelessWidget {
  final Map<String, dynamic> seminar;
  final int regCount;
  final VoidCallback onTap;
  const _HappeningNowBanner({required this.seminar, required this.regCount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF16A34A), Color(0xFF0E7A38)]),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: const Color(0xFF16A34A).withValues(alpha: 0.32), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Row(children: [
          Container(width: 46, height: 46,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.sensors_rounded, color: Colors.white, size: 24)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 7, height: 7, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text('HAPPENING NOW', style: GoogleFonts.nunito(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
            ]),
            const SizedBox(height: 4),
            Text(seminar['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('$regCount attending', style: GoogleFonts.nunito(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 11, fontWeight: FontWeight.w500)),
          ])),
          const SizedBox(width: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.login_rounded, color: Color(0xFF0E7A38), size: 15),
                const SizedBox(width: 4),
                Text('Join', style: GoogleFonts.nunito(color: const Color(0xFF0E7A38), fontSize: 12, fontWeight: FontWeight.w900)),
              ])),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  YOUR NEXT SEMINAR HIGHLIGHT
// ─────────────────────────────────────────────────────────────────────────────
class _NextSeminarHighlight extends StatelessWidget {
  final Map<String, dynamic> seminar;
  final VoidCallback onTap;
  const _NextSeminarHighlight({required this.seminar, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: const Border(left: BorderSide(color: AppColors.primary, width: 4)),
          boxShadow: [BoxShadow(color: AppColors.primary.withValues(alpha: 0.07), blurRadius: 12, offset: const Offset(0, 2))],
        ),
        child: Row(children: [
          Container(width: 44, height: 44,
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.event_available_rounded, color: AppColors.primary, size: 22)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('YOUR NEXT SEMINAR', style: GoogleFonts.nunito(
                fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: AppColors.primaryLight)),
            const SizedBox(height: 3),
            Text(seminar['title'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.textDark)),
            const SizedBox(height: 2),
            Text(_fmtDate(seminar['scheduled_start'] as String?),
                style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.textLight)),
          ])),
          const Icon(Icons.chevron_right_rounded, color: AppColors.textLight, size: 20),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SEMINAR DETAIL SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class SeminarDetailScreen extends StatefulWidget {
  final Map<String, dynamic> seminar;
  final SeminarRegistrationState regState;
  final Future<void> Function() onRegister;
  const SeminarDetailScreen({super.key, required this.seminar, required this.regState, required this.onRegister});
  @override
  State<SeminarDetailScreen> createState() => _SeminarDetailScreenState();
}

class _SeminarDetailScreenState extends State<SeminarDetailScreen> with WidgetsBindingObserver {
  bool _registering = false, _hasEvaluated = false, _evalLoading = false;
  bool _evalSubmitted = false, _checkingEval = true, _regStateReady = false;
  // Only participants who actually joined the live session may evaluate
  bool _attended = false, _checkingAttendance = true;
  // Live copy of the seminar so status changes (e.g. admin ended the meeting) show up
  late Map<String, dynamic> _sem;
  Timer? _statusTimer;
  final TextEditingController _commentCtrl = TextEditingController();
  final Map<String, int> _scores = {
    'q_content': 0, 'q_speaker': 0, 'q_organization': 0,
    'q_relevance': 0, 'q_materials': 0, 'q_overall': 0,
  };
  static const Map<String, String> _evalLabels = {
    'q_content': 'Content Quality', 'q_speaker': 'Speaker Effectiveness',
    'q_organization': 'Event Organization', 'q_relevance': 'Relevance to GAD',
    'q_materials': 'Materials & Resources', 'q_overall': 'Overall Satisfaction',
  };
  static const Map<String, String> _evalDescs = {
    'q_content': 'Relevance and accuracy of the seminar content',
    'q_speaker': 'Clarity, knowledge, and delivery of the speaker(s)',
    'q_organization': 'Logistics, time management, and flow of the event',
    'q_relevance': 'How relevant was this activity to gender and development?',
    'q_materials': 'Quality of presentation materials and handouts',
    'q_overall': 'Your overall experience with this seminar',
  };

  @override
  void initState() {
    super.initState();
    _sem = Map<String, dynamic>.from(widget.seminar);
    WidgetsBinding.instance.addObserver(this);
    _checkEvaluation();
    _checkAttendance();
    _refreshSeminar();
    widget.regState.addListener(_onRegStateChanged);
    _statusTimer = Timer.periodic(const Duration(seconds: 15), (_) => _refreshSeminar());
    if (widget.regState.loaded) _regStateReady = true;
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.regState.removeListener(_onRegStateChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the meeting: refresh status and attendance right away
    if (state == AppLifecycleState.resumed) {
      _refreshSeminar();
      _checkAttendance();
    }
  }

  Future<void> _refreshSeminar() async {
    try {
      final fresh = await _db.from('seminars').select('*')
          .eq('id', widget.seminar['id']).maybeSingle();
      if (!mounted) return;
      setState(() { if (fresh != null) _sem = {..._sem, ...fresh}; });
    } catch (_) {
      if (mounted) setState(() {}); // still re-evaluate time-based status
    }
  }

  Future<void> _checkAttendance() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() { _attended = false; _checkingAttendance = false; });
      return;
    }
    try {
      final rows = await _db.from('seminar_attendance_logs').select('id')
          .eq('seminar_id', widget.seminar['id']).eq('user_id', userId).limit(1);
      if (mounted) setState(() { _attended = (rows as List).isNotEmpty; _checkingAttendance = false; });
    } catch (_) {
      if (mounted) setState(() { _attended = false; _checkingAttendance = false; });
    }
  }

  void _onRegStateChanged() { if (mounted) setState(() { _regStateReady = widget.regState.loaded; }); }

  Future<void> _checkEvaluation() async {
    setState(() => _checkingEval = true);
    final result = await DatabaseService.hasEvaluated(widget.seminar['id'] as String);
    if (mounted) setState(() { _hasEvaluated = result; _checkingEval = false; });
  }

  Future<void> _submitEvaluation() async {
    final semId = widget.seminar['id'] as String;
    if (!widget.regState.isRegistered(semId)) {
      _showSnack('Only registered participants can evaluate this seminar.', isError: true); return;
    }
    if (!_attended) {
      _showSnack('Only participants who attended the live session can evaluate this seminar.', isError: true); return;
    }
    if (_scores.values.any((v) => v == 0)) {
      _showSnack('Please rate all criteria before submitting.', isError: true); return;
    }
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Submit Evaluation?', style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
      content: Text('Once submitted, your evaluation cannot be changed. Are you sure?',
          style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[700], height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: GoogleFonts.nunito(color: AppColors.textMid))),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryDark,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), elevation: 0),
            child: Text('Submit', style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w700))),
      ],
    ));
    if (confirmed != true || !mounted) return;
    setState(() => _evalLoading = true);
    final err = await DatabaseService.submitEvaluation(seminarId: semId, scores: _scores, comments: _commentCtrl.text);
    if (!mounted) return;
    if (err == null) {
      setState(() { _hasEvaluated = true; _evalSubmitted = true; _evalLoading = false; });
    } else if (err == 'already_evaluated') {
      setState(() { _hasEvaluated = true; _evalLoading = false; });
      _showSnack('You have already evaluated this seminar.');
    } else {
      setState(() => _evalLoading = false);
      _showSnack('Submission failed. Please try again.', isError: true);
    }
  }

  Future<void> _handleRegister() async {
    if (_registering) return;
    setState(() => _registering = true);
    await widget.onRegister();
    if (mounted) setState(() => _registering = false);
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.nunito()),
      backgroundColor: isError ? AppColors.danger : AppColors.primary));
  }

  String _scoreLabel(int s) => ['', 'Poor', 'Fair', 'Good', 'Very Good', 'Excellent'][s.clamp(0, 5)];
  Color _statusColor(String? s) {
    switch (s) {
      case 'ongoing':   return const Color(0xFF16A34A);
      case 'completed': return const Color(0xFF2563EB);
      case 'cancelled': return const Color(0xFFDC2626);
      default:          return const Color(0xFFF59E0B);
    }
  }


  @override
  Widget build(BuildContext context) {
    final sem      = _sem;
    final semId    = sem['id'] as String;
    final status   = _effectiveStatus(sem);
    final isReg    = widget.regState.isRegistered(semId);
    final isOpen   = _registrationOpen(sem);
    final type     = sem['seminar_type'] as String? ?? 'webinar';
    final title    = sem['title'] as String? ?? '';
    final hasLink  = type != 'in_person' && status == 'ongoing'; // Only show join when meeting is live
    final hasEnded = _seminarHasEnded(sem);
    final showRegBtn      = status != 'completed' && status != 'cancelled';
    final showEvalSection = _regStateReady && status == 'completed' && isReg && !_checkingAttendance && _attended;
    final showNotAttended = _regStateReady && status == 'completed' && isReg && !_checkingAttendance && !_attended;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F9F0),
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: sem['cover_image_url'] != null ? 260 : 200, pinned: true,
          backgroundColor: AppColors.primaryDark,
          leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
          flexibleSpace: FlexibleSpaceBar(
            background: sem['cover_image_url'] != null
                ? Stack(fit: StackFit.expand, children: [
                    Image.network(sem['cover_image_url'], fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: AppColors.primaryDark)),
                    Container(decoration: BoxDecoration(gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)]))),
                    Positioned(bottom: 20, left: 20, right: 20, child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: _statusColor(status).withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white))),
                      const SizedBox(height: 8),
                      Text(title, maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.nunito(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white)),
                    ])),
                  ])
                : Container(
                    decoration: const BoxDecoration(gradient: LinearGradient(
                        colors: [AppColors.primaryDark, AppColors.primary], begin: Alignment.topLeft, end: Alignment.bottomRight)),
                    padding: const EdgeInsets.fromLTRB(20, 80, 20, 20),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.end, children: [
                      Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: _statusColor(status).withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
                          child: Text(status.toUpperCase(), style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white))),
                      const SizedBox(height: 8),
                      Text(title, maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.nunito(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.white)),
                    ])),
          ),
        ),
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: _TypeBadge(
                icon: type == 'in_person' ? Icons.location_on_outlined : type == 'hybrid' ? Icons.device_hub_outlined : Icons.videocam_outlined,
                text: type == 'in_person' ? 'In Person' : type == 'hybrid' ? 'Hybrid' : 'Webinar')),
            const SizedBox(width: 8),
            if (isReg) const Flexible(child: _TypeBadge(icon: Icons.check_circle_outline, text: 'Registered', color: Color(0xFF16A34A))),
          ]),
          const SizedBox(height: 20),
          _DetailCard(children: [
            _DetailRow(Icons.calendar_today_outlined, 'Start', _fmtDate(sem['scheduled_start'] as String?)),
            if (sem['scheduled_end'] != null) _DetailRow(Icons.flag_outlined, 'End', _fmtDate(sem['scheduled_end'] as String?)),
            if (sem['venue'] != null) _DetailRow(Icons.location_on_outlined, 'Venue', sem['venue']),
            if (hasLink) _DetailRow(Icons.videocam_outlined, 'Meeting', 'Jitsi Meet (Online)'),
          ]),
          const SizedBox(height: 20),
          if (sem['description'] != null && (sem['description'] as String).isNotEmpty) ...[
            Text('About this Seminar', style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
            const SizedBox(height: 10),
            Container(width: double.infinity, padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 6)]),
                child: Text(sem['description'], style: GoogleFonts.nunito(fontSize: 14, color: const Color(0xFF444444), height: 1.6))),
            const SizedBox(height: 20),
          ],
          if (hasLink) ...[
            if (!isReg) ...[
              Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.grey[300]!)),
                  child: Row(children: [
                    Icon(Icons.lock_outline, size: 18, color: Colors.grey[500]), const SizedBox(width: 10),
                    Expanded(child: Text('You must be registered for this seminar to join the meeting.',
                        style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[600], height: 1.4))),
                  ])),
              const SizedBox(height: 10),
            ] else if (hasEnded) ...[
              Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(color: Colors.orange[50], borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange[200]!)),
                  child: Row(children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.orange[700]), const SizedBox(width: 10),
                    Expanded(child: Text('This seminar has already ended and is no longer available to join.',
                        style: GoogleFonts.nunito(fontSize: 13, color: Colors.orange[800], height: 1.4))),
                  ])),
              const SizedBox(height: 10),
            ],
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: (!hasEnded && isReg) ? () => _joinJitsiMeeting(context, sem, isRegistered: isReg) : null,
              icon: Icon(hasEnded ? Icons.link_off_rounded : (!isReg ? Icons.lock_outline : Icons.open_in_new), size: 18),
              label: Text(hasEnded ? 'Seminar Ended' : !isReg ? 'Registration Required' : 'Join Meeting',
                  style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 15)),
              style: OutlinedButton.styleFrom(
                  foregroundColor: (hasEnded || !isReg) ? Colors.grey[400] : AppColors.primary,
                  side: BorderSide(color: (hasEnded || !isReg) ? Colors.grey[300]! : AppColors.primary, width: 2),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            )),
            const SizedBox(height: 12),
          ],
          if (showRegBtn) ...[
            SizedBox(width: double.infinity,
                child: isOpen || isReg
                    ? ElevatedButton(
                        onPressed: _registering ? null : _handleRegister,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: isReg ? Colors.grey[200] : AppColors.primary,
                            foregroundColor: isReg ? Colors.grey[700] : Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                        child: _registering
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                            : Text(isReg ? 'Registered — Tap to Cancel' : 'Register for this Seminar',
                                style: GoogleFonts.nunito(fontWeight: FontWeight.w900, fontSize: 15)))
                    : Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 15),
                        decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(12)),
                        child: Center(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.lock_outline, size: 16, color: Colors.grey[600]), const SizedBox(width: 8),
                          Text('Closed', style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.grey[600])),
                        ])))),
          ] else ...[
            Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(12)),
                child: Center(child: Text(status == 'completed' ? 'Seminar Completed' : 'Seminar Cancelled',
                    style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.grey[600])))),
          ],
          const SizedBox(height: 24),
          if (showEvalSection) ...[
            if (_checkingEval)
              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: AppColors.primary)))
            else
              Container(width: double.infinity,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)],
                      border: Border.all(color: const Color(0xFFE8F2D8))),
                  child: (_hasEvaluated || _evalSubmitted) ? _buildEvalDone() : _buildEvalForm()),
            const SizedBox(height: 32),
          ] else if (showNotAttended) ...[
            Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!)),
                child: Row(children: [
                  Icon(Icons.lock_outline, size: 18, color: Colors.grey[400]), const SizedBox(width: 10),
                  Expanded(child: Text('Only participants who attended the live session can evaluate this seminar.',
                      style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[500], height: 1.4))),
                ])),
            const SizedBox(height: 32),
          ] else if (status == 'completed' && _regStateReady && !isReg) ...[
            Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!)),
                child: Row(children: [
                  Icon(Icons.lock_outline, size: 18, color: Colors.grey[400]), const SizedBox(width: 10),
                  Expanded(child: Text('Only registered participants can evaluate this seminar.',
                      style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[500], height: 1.4))),
                ])),
            const SizedBox(height: 32),
          ] else const SizedBox(height: 32),
        ]))),
      ]),
    );
  }

  Widget _buildEvalDone() => Padding(padding: const EdgeInsets.all(24),
      child: Column(children: [
        Container(width: 64, height: 64,
            decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.check_circle_outline, color: Color(0xFF2D6A2D), size: 36)),
        const SizedBox(height: 14),
        Text('Evaluation Submitted!', style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.primaryDark)),
        const SizedBox(height: 6),
        Text('Thank you for your feedback. It helps us improve.', textAlign: TextAlign.center,
            style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[600], height: 1.5)),
      ]));

  Widget _buildEvalForm() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Container(padding: const EdgeInsets.all(18),
        decoration: const BoxDecoration(gradient: LinearGradient(
            colors: [AppColors.primaryDark, AppColors.primary],
            begin: Alignment.centerLeft, end: Alignment.centerRight),
            borderRadius: BorderRadius.vertical(top: Radius.circular(15))),
        child: Row(children: [
          const Icon(Icons.assignment_outlined, color: Colors.white, size: 22), const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Seminar Evaluation Form', style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)),
            Text('Rate each criterion from 1 (Poor) to 5 (Excellent)', style: GoogleFonts.nunito(fontSize: 11, color: Colors.white70)),
          ])),
        ])),
    ..._evalLabels.entries.map((entry) {
      final key = entry.key; final label = entry.value;
      final desc = _evalDescs[key] ?? ''; final score = _scores[key] ?? 0;
      return Container(padding: const EdgeInsets.fromLTRB(16, 14, 16, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primaryDark)),
            Text(desc, style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500])),
          ])),
          if (score > 0) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(20)),
              child: Text(_scoreLabel(score), style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary))),
        ]),
        const SizedBox(height: 8),
        Row(children: List.generate(5, (i) {
          final star = i + 1;
          return Expanded(child: GestureDetector(
            onTap: () => setState(() => _scores[key] = star),
            child: Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                  color: score >= star ? AppColors.primary : const Color(0xFFF5F7F5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: score >= star ? AppColors.primary : const Color(0xFFDDE8DD))),
              child: Center(child: Text('$star', style: GoogleFonts.nunito(fontSize: 14, fontWeight: FontWeight.w800,
                  color: score >= star ? Colors.white : Colors.grey[500]))),
            ),
          ));
        })),
        const SizedBox(height: 12),
        Divider(color: Colors.grey[100], height: 1),
      ]));
    }),
    Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Additional Comments', style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.primaryDark)),
      const SizedBox(height: 8),
      TextField(controller: _commentCtrl, maxLines: 3, style: GoogleFonts.nunito(fontSize: 14),
          decoration: InputDecoration(hintText: 'Your comments here…', hintStyle: GoogleFonts.nunito(fontSize: 14, color: Colors.grey),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE8F2D8))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFE8F2D8))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.primary)),
              filled: true, fillColor: const Color(0xFFF6F9F0), contentPadding: const EdgeInsets.all(14))),
      const SizedBox(height: 10),
      SizedBox(width: double.infinity, child: ElevatedButton(
        onPressed: _evalLoading ? null : _submitEvaluation,
        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryDark, foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        child: _evalLoading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text('Submit Evaluation', style: GoogleFonts.nunito(fontWeight: FontWeight.w900, fontSize: 15)),
      )),
    ])),
  ]);
}

// ─────────────────────────────────────────────────────────────────────────────
//  CALENDAR TAB
// ─────────────────────────────────────────────────────────────────────────────
class _CalendarTab extends StatefulWidget {
  final SeminarRegistrationState regState;
  const _CalendarTab({required this.regState});
  @override
  State<_CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<_CalendarTab> {
  List<Map<String, dynamic>> _allItems = [];
  bool _loading = true;
  DateTime _viewDate = DateTime.now();
  String? _selectedDate;

  @override
  void initState() { super.initState(); _load(); widget.regState.addListener(_onRegStateChanged); }
  @override
  void dispose() { widget.regState.removeListener(_onRegStateChanged); super.dispose(); }
  void _onRegStateChanged() { if (mounted) setState(() {}); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _db.from('events').select('*').order('start_date'),
        _db.from('seminars').select('*').eq('is_public', true).order('scheduled_start'),
      ]);
      final events        = List<Map<String, dynamic>>.from(results[0]);
      final seminars      = List<Map<String, dynamic>>.from(results[1]);
      final seminarEvents = seminars.map(_seminarToCalendarEvent).where((e) => e['start_date'] != null).toList();
      final merged        = [...events, ...seminarEvents];
      merged.sort((a, b) => (a['start_date'] as String? ?? '').compareTo(b['start_date'] as String? ?? ''));
      if (mounted) setState(() { _allItems = merged; _loading = false; });
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  List<Map<String, dynamic>> _itemsForDate(String dateStr) {
    return _allItems.where((e) {
      final s     = e['start_date'] as String? ?? '';
      final start = s.length >= 10 ? s.substring(0, 10) : s;
      final en    = (e['end_date'] as String?) ?? start;
      final end   = en.length >= 10 ? en.substring(0, 10) : en;
      return dateStr.compareTo(start) >= 0 && dateStr.compareTo(end) <= 0;
    }).toList();
  }

  Color _parseColor(String? hex) {
    if (hex == null) return AppColors.primary;
    try { return Color(int.parse(hex.replaceAll('#', '0xFF'))); } catch (_) { return AppColors.primary; }
  }

  Color _itemColor(Map<String, dynamic> item) =>
      item['_source'] == 'seminar' ? const Color(0xFF2563EB) : _parseColor(item['color_hex'] as String?);

  Future<void> _toggleRegistration(Map<String, dynamic> raw) async {
    final semId = raw['id'] as String;
    final isReg = widget.regState.isRegistered(semId);
    if (isReg) {
      final err = await DatabaseService.cancelRegistration(semId);
      if (err == null) widget.regState.remove(semId);
    } else {
      final err = await DatabaseService.registerForSeminar(semId);
      if (err == null || err == 'already_registered') widget.regState.add(semId);
    }
  }

  void _showDaySheet(BuildContext ctx, String dateStr) {
    final dayItems = _itemsForDate(dateStr);
    String prettyDate;
    try {
      final d = DateTime.parse(dateStr);
      const weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
      const months   = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      prettyDate = '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}, ${d.year}';
    } catch (_) { prettyDate = dateStr; }

    showModalBottomSheet(context: ctx, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: dayItems.isEmpty ? 0.35 : 0.55, minChildSize: 0.25, maxChildSize: 0.90, expand: false,
        builder: (_, scrollCtrl) => Container(
          decoration: const BoxDecoration(color: Color(0xFFF6F9F0), borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          child: Column(children: [
            Center(child: Container(margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: const BoxDecoration(gradient: LinearGradient(
                    colors: [AppColors.primaryDark, AppColors.primary], begin: Alignment.centerLeft, end: Alignment.centerRight),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                child: Row(children: [
                  const Icon(Icons.calendar_today_rounded, color: Colors.white, size: 18), const SizedBox(width: 10),
                  Expanded(child: Text(prettyDate, style: GoogleFonts.nunito(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800))),
                  if (dayItems.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(20)),
                      child: Text('${dayItems.length} event${dayItems.length == 1 ? '' : 's'}',
                          style: GoogleFonts.nunito(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700))),
                ])),
            Expanded(child: dayItems.isEmpty
                ? Center(child: Text('No events on this date', style: GoogleFonts.nunito(fontSize: 14, color: Colors.grey[500])))
                : ListView.builder(controller: scrollCtrl, padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                    itemCount: dayItems.length,
                    itemBuilder: (ctx2, idx) {
                      final e = dayItems[idx];
                      final isSeminar = e['_source'] == 'seminar';
                      final ac = _itemColor(e);
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          if (isSeminar) {
                            final raw = e['_raw'] as Map<String, dynamic>;
                            Navigator.push(ctx, MaterialPageRoute(builder: (_) => SeminarDetailScreen(
                              seminar: raw, regState: widget.regState,
                              onRegister: () => _toggleRegistration(raw),
                            ))).then((_) => _load());
                          }
                        },
                        child: Container(margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14),
                                border: Border(left: BorderSide(color: ac, width: 4)),
                                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))]),
                            child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(e['title'] ?? '', style: GoogleFonts.nunito(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
                              const SizedBox(height: 4),
                              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(color: ac.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                                  child: Text((e['event_type'] ?? 'event').toString().toUpperCase(),
                                      style: GoogleFonts.nunito(fontSize: 10, fontWeight: FontWeight.w800, color: ac))),
                            ]))),
                      );
                    })),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    final year = _viewDate.year; final month = _viewDate.month;
    final firstDay = DateTime(year, month, 1).weekday % 7;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final today = DateTime.now();
    const monthNames = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    final todayStr = today.toIso8601String().substring(0, 10);
    final upcoming = _allItems.where((e) {
      final s = (e['start_date'] as String? ?? '');
      return s.length >= 10 && s.substring(0, 10).compareTo(todayStr) >= 0;
    }).take(5).toList();

    return RefreshIndicator(color: AppColors.primary, onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        const Row(children: [
          _LegendDot(color: AppColors.primary, label: 'Events'),
          SizedBox(width: 16),
          _LegendDot(color: Color(0xFF2563EB), label: 'Seminars'),
        ]),
        const SizedBox(height: 12),
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)]),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(gradient: LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [AppColors.primaryDark, AppColors.primary]),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  IconButton(icon: const Icon(Icons.chevron_left, color: Colors.white),
                      onPressed: () => setState(() { _viewDate = DateTime(year, month - 1, 1); _selectedDate = null; })),
                  Text('${monthNames[month - 1]} $year', style: GoogleFonts.nunito(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                  IconButton(icon: const Icon(Icons.chevron_right, color: Colors.white),
                      onPressed: () => setState(() { _viewDate = DateTime(year, month + 1, 1); _selectedDate = null; })),
                ])),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(children: ['S','M','T','W','T','F','S'].map((d) => Expanded(
                    child: Center(child: Text(d, style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey))))).toList())),
            GridView.builder(
              shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, childAspectRatio: 0.9),
              itemCount: firstDay + daysInMonth,
              itemBuilder: (ctx, i) {
                if (i < firstDay) return const SizedBox();
                final day = i - firstDay + 1;
                final dateStr = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
                final isToday    = day == today.day && month == today.month && year == today.year;
                final isSelected = _selectedDate == dateStr;
                final dayItems   = _itemsForDate(dateStr);
                final hasEvents  = dayItems.isNotEmpty;
                BoxDecoration cellDeco;
                if (isSelected) {
                  cellDeco = BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(8));
                } else if (isToday) {
                  cellDeco = BoxDecoration(color: AppColors.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.primary, width: 1.5));
                } else {
                  cellDeco = BoxDecoration(color: hasEvents ? AppColors.primary.withValues(alpha: 0.04) : null, borderRadius: BorderRadius.circular(8));
                }
                final Color dayNumColor = isSelected ? Colors.white : isToday ? AppColors.primary : AppColors.primaryDark;
                return GestureDetector(
                  onTap: () { setState(() => _selectedDate = dateStr); _showDaySheet(context, dateStr); },
                  child: Container(margin: const EdgeInsets.all(1), decoration: cellDeco,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text('$day', style: GoogleFonts.nunito(fontSize: 12,
                            fontWeight: isToday || isSelected ? FontWeight.w900 : FontWeight.w500, color: dayNumColor)),
                        if (hasEvents) ...[
                          const SizedBox(height: 2),
                          Wrap(alignment: WrapAlignment.center, spacing: 2,
                              children: dayItems.take(3).map((e) => Container(width: 5, height: 5,
                                  decoration: BoxDecoration(color: isSelected ? Colors.white.withValues(alpha: 0.85) : _itemColor(e),
                                      shape: BoxShape.circle))).toList()),
                        ],
                      ])),
                );
              },
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Text('Upcoming Events & Seminars', style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.primaryDark)),
        const SizedBox(height: 10),
        if (upcoming.isEmpty)
          const _EmptyState(icon: Icons.calendar_month_outlined, title: 'No upcoming events', sub: 'Check back later')
        else
          ...upcoming.map((e) {
            final isSeminar = e['_source'] == 'seminar';
            final ac = _itemColor(e);
            final semId = isSeminar ? (e['_raw'] as Map<String, dynamic>)['id'] as String? : null;
            final isReg = semId != null && widget.regState.isRegistered(semId);
            return GestureDetector(
              onTap: () {
                if (isSeminar) {
                  final raw = e['_raw'] as Map<String, dynamic>;
                  Navigator.push(context, MaterialPageRoute(builder: (_) => SeminarDetailScreen(
                    seminar: raw, regState: widget.regState,
                    onRegister: () => _toggleRegistration(raw),
                  ))).then((_) => _load());
                }
              },
              child: Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                      border: Border(left: BorderSide(color: ac, width: 4)),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 5)]),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(e['title'] ?? '', style: GoogleFonts.nunito(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.primaryDark))),
                      if (isReg) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(color: const Color(0xFF16A34A).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                          child: Text('Registered', style: GoogleFonts.nunito(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF16A34A)))),
                    ]),
                    const SizedBox(height: 4),
                    Text(_fmtDateShort(e['start_date'] as String?), style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 6),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: ac.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                        child: Text((e['event_type'] ?? 'event').toString().toUpperCase(),
                            style: GoogleFonts.nunito(fontSize: 10, fontWeight: FontWeight.w800, color: ac))),
                  ])),
            );
          }),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SHARED SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _TypeBadge extends StatelessWidget {
  final IconData icon; final String text; final Color? color;
  const _TypeBadge({required this.icon, required this.text, this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(color: (color ?? AppColors.primary).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: color ?? AppColors.primary), const SizedBox(width: 5),
      Text(text, style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w700, color: color ?? AppColors.primary)),
    ]),
  );
}

class _DetailCard extends StatelessWidget {
  final List<Widget> children;
  const _DetailCard({required this.children});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8)]),
    child: Column(children: children),
  );
}

class _DetailRow extends StatelessWidget {
  final IconData icon; final String label, value;
  const _DetailRow(this.icon, this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 12),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: AppColors.primary), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey, letterSpacing: 0.5)),
        const SizedBox(height: 2),
        Text(value, style: GoogleFonts.nunito(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.primaryDark)),
      ])),
    ]));
}

class _InfoRow extends StatelessWidget {
  final IconData icon; final String text;
  const _InfoRow({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 4),
    child: Row(children: [
      Icon(icon, size: 13, color: Colors.grey[500]), const SizedBox(width: 6),
      Expanded(child: Text(text, style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]))),
    ]));
}

class _LegendDot extends StatelessWidget {
  final Color color; final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 5),
    Text(label, style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600])),
  ]);
}

class _EmptyState extends StatelessWidget {
  final IconData icon; final String title, sub;
  const _EmptyState({required this.icon, required this.title, required this.sub});
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(40),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 48, color: Colors.grey[400]), const SizedBox(height: 12),
      Text(title, style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.grey[600])),
      const SizedBox(height: 6),
      Text(sub, textAlign: TextAlign.center, style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey)),
    ])));
}