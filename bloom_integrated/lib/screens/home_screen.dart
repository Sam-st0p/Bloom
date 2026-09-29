// lib/screens/home_screen.dart

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/common_widgets.dart';
import '../services/activity_service.dart';

class LiveSeminar {
  final String id;
  final String title;
  final int attendees;
  final String statusLabel;
  const LiveSeminar(this.id, this.title, this.attendees, this.statusLabel);
}

class HomeScreen extends StatefulWidget {
  final void Function(int tabIndex) onSwitchTab;
  final VoidCallback onOpenNotifications;
  final int unreadCount;
  final void Function(LiveSeminar seminar)? onJoinLive;

  /// Opens the Calendar sub-tab of Events directly.
  final VoidCallback? onOpenCalendar;

  /// Role pre-resolved by AuthGate and passed down through MainShell.
  /// When non-empty it is used instead of the DB value, which avoids
  /// Google users briefly seeing 'Student' before the guest upsert finishes.
  final String resolvedRole;

  const HomeScreen({
    super.key,
    required this.onSwitchTab,
    required this.onOpenNotifications,
    required this.unreadCount,
    this.onJoinLive,
    this.onOpenCalendar,
    this.resolvedRole = '',
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _supabase = Supabase.instance.client;

  String _firstName = '';
  String _fullName = '';
  String _role = '';
  int _completedModules = 0;
  int _totalModules = 0;
  int _badgeCount = 0;
  int _seminarCount = 0;

  List<ModuleModel> _inProgressModules = [];
  List<EventModel> _upcomingEvents = [];
  List<Map<String, dynamic>> _announcements = [];
  LiveSeminar? _live;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Seed the role so the pill is correct before the DB fetch completes.
    if (widget.resolvedRole.isNotEmpty) _role = widget.resolvedRole;
    _loadAll();
    ActivityService.log(activityType: 'screen_view', referenceType: 'home');
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final nowUtc = DateTime.now().toUtc().toIso8601String();

      // All queries are independent, so run them in parallel.
      final (
        profile,
        modulesData,
        progressData,
        badgeRes,
        seminarRes,
        eventsData,
        announcementsData,
        live,
      ) = await (
        _supabase
            .from('profiles')
            .select('full_name, role')
            .eq('id', userId)
            .maybeSingle(),
        _supabase
            .from('modules')
            .select('*, categories(name)')
            .eq('status', 'published'),
        _supabase
            .from('module_progress')
            .select('module_id, progress_percent, status')
            .eq('user_id', userId),
        _supabase
            .from('student_badges')
            .select('id')
            .eq('user_id', userId)
            .count(CountOption.exact),
        _supabase
            .from('seminar_registrations')
            .select('id')
            .eq('user_id', userId)
            .count(CountOption.exact),
        _supabase
            .from('events')
            .select('*')
            .gte('start_date', today)
            .order('start_date')
            .limit(5),
        _supabase
            .from('announcements')
            .select('id, title, body, is_pinned, published_at')
            .lte('published_at', nowUtc)
            .order('is_pinned', ascending: false)
            .order('published_at', ascending: false)
            .limit(3),
        _fetchLiveSeminar(),
      ).wait;

      final progressMap = {
        for (final p in progressData) p['module_id'] as String: p,
      };

      final allModules = modulesData.map((m) {
        final pct =
            (progressMap[m['id']]?['progress_percent'] as num?)?.toInt() ?? 0;
        return ModuleModel.fromMap(m, progress: pct);
      }).toList();

      if (!mounted) return;
      setState(() {
        final fullName = profile?['full_name'] as String? ?? '';
        _fullName = fullName.isEmpty ? 'Welcome!' : fullName;
        _firstName = fullName.isEmpty ? '' : fullName.split(' ').first;

        final dbRole = profile?['role'] as String? ?? '';
        _role = widget.resolvedRole.isNotEmpty ? widget.resolvedRole : dbRole;

        _totalModules = allModules.length;
        _completedModules = allModules.where((m) => m.progress == 100).length;
        _inProgressModules = allModules
            .where((m) => m.progress > 0 && m.progress < 100)
            .toList();
        _badgeCount = badgeRes.count;
        _seminarCount = seminarRes.count;
        _upcomingEvents = eventsData.map(EventModel.fromMap).toList();
        _announcements = List<Map<String, dynamic>>.from(announcementsData);
        _live = live;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('HomeScreen._loadAll failed: $e\n$st');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<LiveSeminar?> _fetchLiveSeminar() async {
    try {
      // UTC so timestamptz comparisons aren't off by the local offset.
      final nowUtc = DateTime.now().toUtc().toIso8601String();
      final rows = await _supabase
          .from('events')
          .select('id, title, start_date, end_date')
          .lte('start_date', nowUtc)
          .gte('end_date', nowUtc)
          .order('start_date')
          .limit(1);

      if (rows.isEmpty) return null;
      final row = rows.first;

      int attendees = 0;
      try {
        final regs = await _supabase
            .from('seminar_registrations')
            .select('id')
            .eq('seminar_id', row['id'])
            .count(CountOption.exact);
        attendees = regs.count;
      } catch (e) {
        debugPrint('Failed to load attendees for ${row['id']}: $e');
      }

      return LiveSeminar(
        row['id'].toString(),
        row['title'] as String? ?? 'Live session',
        attendees,
        'happening now',
      );
    } catch (e) {
      debugPrint('Failed to load live seminar: $e');
      return null;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning,';
    if (h < 18) return 'Good afternoon,';
    return 'Good evening,';
  }

  String _roleLabel() {
    switch (_role) {
      case 'teacher': return 'Teacher';
      case 'faculty': return 'Faculty';
      case 'guest':   return 'Guest';
      case 'student': return 'Student';
      default:        return _role.isEmpty ? 'Student' : _role;
    }
  }

  int get _overall => _totalModules == 0
      ? 0
      : ((_completedModules / _totalModules) * 100).round();

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    return parts.take(2).map((p) => p[0]).join().toUpperCase();
  }

  void _openModule(ModuleModel m) {
    ActivityService.log(
      activityType: 'module_opened',
      referenceId: m.id,
      referenceType: 'module',
      metadata: {'title': m.title},
    );
    widget.onSwitchTab(1);
  }

  void _openCalendar() {
    if (widget.onOpenCalendar != null) {
      widget.onOpenCalendar!();
    } else {
      widget.onSwitchTab(2); // fallback: Events tab
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _loadAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 60),
                  child: Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: _body(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_live != null) ...[
          _LiveBanner(
            seminar: _live!,
            onTap: () => widget.onJoinLive != null
                ? widget.onJoinLive!(_live!)
                : widget.onSwitchTab(2),
          ),
          const SizedBox(height: 18),
        ],

        _quickActions(),
        const SizedBox(height: 20),

        if (_announcements.isNotEmpty) ...[
          SectionHeader(
            title: 'Announcements',
            action: 'See all',
            onAction: widget.onOpenNotifications,
          ),
          const SizedBox(height: 12),
          ..._announcements.map((a) => _AnnouncementCard(a: a)),
          const SizedBox(height: 8),
        ],

        SectionHeader(
          title: 'Continue Learning',
          action: 'View all',
          onAction: () => widget.onSwitchTab(1),
        ),
        const SizedBox(height: 12),
        if (_inProgressModules.isEmpty)
          _EmptyState(
            message: "You haven't started a module yet.",
            actionLabel: 'Go to Library',
            onAction: () => widget.onSwitchTab(1),
          )
        else ...[
          _ResumeHero(
            module: _inProgressModules.first,
            onTap: () => _openModule(_inProgressModules.first),
          ),
          for (final m in _inProgressModules.skip(1).take(2))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _ContinueRow(module: m, onTap: () => _openModule(m)),
            ),
        ],
        const SizedBox(height: 20),

        SectionHeader(
          title: 'Upcoming Events',
          action: 'See all',
          onAction: () => widget.onSwitchTab(2),
        ),
        const SizedBox(height: 12),
        if (_upcomingEvents.isEmpty)
          _EmptyState(
            message: 'No events scheduled yet — check back soon.',
            actionLabel: 'View calendar',
            onAction: () => widget.onSwitchTab(2),
          )
        else
          _upcomingStrip(),
      ],
    );
  }

  Widget _header() {
    return GradientHeader(
      bottomPadding: 20,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initials(_fullName),
                    style: GoogleFonts.nunito(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _greeting,
                        style: GoogleFonts.nunito(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _firstName.isEmpty ? _fullName : _firstName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _roleLabel(),
                          style: GoogleFonts.nunito(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _bell(),
              ],
            ),
            const SizedBox(height: 16),
            _journeyRingStrip(),
          ],
        ),
      ),
    );
  }

  Widget _bell() {
    return GestureDetector(
      onTap: widget.onOpenNotifications,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.notifications_outlined,
                color: Colors.white, size: 22),
            if (widget.unreadCount > 0)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${widget.unreadCount}',
                    style: GoogleFonts.nunito(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _journeyRingStrip() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CustomPaint(
              painter: _RingPainter(_overall / 100),
              child: Center(
                child: Text(
                  '$_overall%',
                  style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your GAD journey',
                  style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_completedModules of $_totalModules modules complete · '
                  '$_badgeCount badges · $_seminarCount seminars',
                  style: GoogleFonts.nunito(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickActions() {
    final items = <(IconData, String, Color, VoidCallback)>[
      (Icons.menu_book_rounded, 'Modules', AppColors.primary,
          () => widget.onSwitchTab(1)),
      (Icons.school_rounded, 'Seminars', AppColors.purple,
          () => widget.onSwitchTab(2)),
      (Icons.workspace_premium_rounded, 'Certificates', AppColors.accent,
          () => widget.onSwitchTab(3)),
      (Icons.calendar_month_rounded, 'Calendar', AppColors.info,
          _openCalendar),
    ];

    return Row(
      children: [
        for (final (icon, label, color, onTap) in items)
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMid,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _upcomingStrip() {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _upcomingEvents.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => _EventCard(
          event: _upcomingEvents[i],
          onTap: () => widget.onSwitchTab(2),
        ),
      ),
    );
  }
}

// ── Live banner ───────────────────────────────────────────────────────────────
class _LiveBanner extends StatelessWidget {
  final LiveSeminar seminar;
  final VoidCallback onTap;
  const _LiveBanner({required this.seminar, required this.onTap});

  static const _green = Color(0xFF16A34A);
  static const _greenDark = Color(0xFF0E7A38);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_green, _greenDark],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: _green.withValues(alpha: 0.32),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.sensors_rounded,
                  color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'LIVE NOW',
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    seminar.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.nunito(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    seminar.attendees > 0
                        ? '${seminar.attendees} attending · ${seminar.statusLabel}'
                        : seminar.statusLabel,
                    style: GoogleFonts.nunito(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.login_rounded, color: _greenDark, size: 15),
                  const SizedBox(width: 4),
                  Text(
                    'Join',
                    style: GoogleFonts.nunito(
                      color: _greenDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Resume hero ───────────────────────────────────────────────────────────────
class _ResumeHero extends StatelessWidget {
  final ModuleModel module;
  final VoidCallback onTap;
  const _ResumeHero({required this.module, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.07),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primaryDark, AppColors.primary],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'In progress',
                      style: GoogleFonts.nunito(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    module.title,
                    style: GoogleFonts.nunito(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppProgressBar(value: module.progress),
                        const SizedBox(height: 5),
                        Text(
                          '${module.progress}% complete',
                          style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.4),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          'Resume',
                          style: GoogleFonts.nunito(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Continue row ──────────────────────────────────────────────────────────────
class _ContinueRow extends StatelessWidget {
  final ModuleModel module;
  final VoidCallback onTap;
  const _ContinueRow({required this.module, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AppCard(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.menu_book_rounded,
                  color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    module.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 6),
                  AppProgressBar(value: module.progress),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textLight, size: 18),
          ],
        ),
      ),
    );
  }
}

// ── Event card ────────────────────────────────────────────────────────────────
class _EventCard extends StatelessWidget {
  final EventModel event;
  final VoidCallback onTap;
  const _EventCard({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = Color(event.colorValue);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 158,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 5, color: color),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.calendar_today_rounded, color: color, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        event.date,
                        style: GoogleFonts.nunito(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 32,
                    child: Text(
                      event.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textDark,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  BadgeChip(label: event.category, color: color),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Announcement card ─────────────────────────────────────────────────────────
class _AnnouncementCard extends StatelessWidget {
  final Map<String, dynamic> a;
  const _AnnouncementCard({required this.a});

  @override
  Widget build(BuildContext context) {
    final pinned = a['is_pinned'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pinned
            ? AppColors.primary.withValues(alpha: 0.07)
            : AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: pinned
              ? AppColors.primary.withValues(alpha: 0.25)
              : AppColors.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pinned)
            const Padding(
              padding: EdgeInsets.only(right: 8, top: 2),
              child: Icon(Icons.push_pin_rounded,
                  size: 14, color: AppColors.primary),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a['title'] as String? ?? '',
                  style: GoogleFonts.nunito(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: AppColors.textDark,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  a['body'] as String? ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.nunito(
                      fontSize: 12, color: AppColors.textLight),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  const _EmptyState({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(fontSize: 13, color: AppColors.textLight),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onAction,
            child: Text(
              actionLabel,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Progress ring painter ─────────────────────────────────────────────────────
class _RingPainter extends CustomPainter {
  final double pct;
  _RingPainter(this.pct);

  static const _stroke = 7.0;
  static const _startAngle = -1.5708; // -π/2, i.e. 12 o'clock
  static const _fullCircle = 6.2832;  // 2π

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - _stroke) / 2;

    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke;
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      _startAngle,
      _fullCircle * pct,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.pct != pct;
}