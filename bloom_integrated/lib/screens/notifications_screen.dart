import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'notification_provider.dart';

// ─────────────────────────────────────────────────────────────────
//  TYPE → ICON / COLOR / LABEL
// ─────────────────────────────────────────────────────────────────
IconData _notifIcon(String? type) {
  switch (type) {
    case 'announcement':         return Icons.campaign_outlined;
    case 'new_seminar':          return Icons.school_outlined;
    case 'new_module':           return Icons.menu_book_outlined;
    case 'new_assessment':       return Icons.quiz_outlined;
    case 'registration':         return Icons.how_to_reg_outlined;
    case 'new_certificate':      return Icons.workspace_premium_outlined;
    case 'new_achievement':      return Icons.emoji_events_outlined;
    case 'evaluation_available': return Icons.rate_review_outlined;
    case 'seminar_reminder':     return Icons.alarm_outlined;
    case 'event_reminder':       return Icons.event_outlined;
    case 'new_event':            return Icons.event_outlined;
    case 'account_deactivated':  return Icons.block_outlined;
    case 'account_reactivated':  return Icons.check_circle_outline;
    case 'role_changed':         return Icons.manage_accounts_outlined;
    case 'registration_removed': return Icons.person_remove_outlined;
    default:                     return Icons.notifications_outlined;
  }
}

Color _notifColor(String? type) {
  switch (type) {
    case 'announcement':         return AppColors.primary;
    case 'new_seminar':          return const Color(0xFF2563EB);
    case 'new_module':           return const Color(0xFFF59E0B);
    case 'new_assessment':       return const Color(0xFF0891B2);
    case 'registration':         return const Color(0xFF16A34A);
    case 'new_certificate':      return const Color(0xFF7C3AED);
    case 'new_achievement':      return const Color(0xFFD97706);
    case 'evaluation_available': return const Color(0xFFDC2626);
    case 'seminar_reminder':     return const Color(0xFFDC2626);
    case 'event_reminder':       return const Color(0xFFDC2626);
    case 'new_event':            return const Color(0xFF0891B2);
    case 'account_deactivated':  return const Color(0xFFDC2626);
    case 'account_reactivated':  return const Color(0xFF16A34A);
    case 'role_changed':         return const Color(0xFF7C3AED);
    case 'registration_removed': return const Color(0xFFF59E0B);
    default:                     return AppColors.textLight;
  }
}

String _notifLabel(String? type) {
  switch (type) {
    case 'announcement':         return 'Announcement';
    case 'new_seminar':          return 'New Seminar';
    case 'new_module':           return 'New Module';
    case 'new_assessment':       return 'Assessment';
    case 'registration':         return 'Registration';
    case 'new_certificate':      return 'Certificate';
    case 'new_achievement':      return 'Achievement';
    case 'evaluation_available': return 'Evaluation';
    case 'seminar_reminder':     return 'Reminder';
    case 'event_reminder':       return 'Reminder';
    case 'new_event':            return 'New Event';
    case 'account_deactivated':  return 'Account';
    case 'account_reactivated':  return 'Account';
    case 'role_changed':         return 'Role Update';
    case 'registration_removed': return 'Registration';
    default:                     return 'Notification';
  }
}

String _timeAgo(String? iso) {
  if (iso == null) return '';
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return '';
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1)  return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours   < 24) return '${diff.inHours}h ago';
  if (diff.inDays    < 7)  return '${diff.inDays}d ago';
  return '${dt.day}/${dt.month}/${dt.year}';
}

// ─────────────────────────────────────────────────────────────────
//  NAV RESULT — returned to MainShell via Navigator.pop()
//
//    library      → tab 1 (Library / Modules)
//    events       → tab 2 (Events → Seminars sub-tab)
//    calendar     → tab 2 (Events → Calendar sub-tab)
//    achievements → tab 3 (Badges → Achievements sub-tab)
//    certificates → tab 3 (Badges → Certificates sub-tab)
// ─────────────────────────────────────────────────────────────────
enum NavResult { library, events, calendar, achievements, certificates }

// ─────────────────────────────────────────────────────────────────
//  NOTIFICATIONS SCREEN
// ─────────────────────────────────────────────────────────────────
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with SingleTickerProviderStateMixin {
  bool _showUnread = false;

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeIn);
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  // ── Tap: mark read + navigate ──────────────────────────────────
  void _handleTap(NotificationProvider provider, Map<String, dynamic> n) {
    final id   = n['id'].toString();
    final type = n['type'] as String?;

    if (n['is_read'] != true) provider.markRead(id);

    switch (type) {
      case 'new_module':
      case 'new_assessment':
        Navigator.pop(context, NavResult.library);
        break;

      case 'new_seminar':
      case 'seminar_reminder':
      case 'evaluation_available':
        Navigator.pop(context, NavResult.events);
        break;

      case 'new_event':
      case 'event_reminder':
        Navigator.pop(context, NavResult.calendar);
        break;

      case 'new_certificate':
        Navigator.pop(context, NavResult.certificates);
        break;

      case 'new_achievement':
        Navigator.pop(context, NavResult.achievements);
        break;

      // Announcements, account/role changes, unknown → detail sheet
      case 'announcement':
      case 'account_deactivated':
      case 'account_reactivated':
      case 'role_changed':
      case 'registration_removed':
      default:
        _showDetail(n);
        break;
    }
  }

  // ── Mark all read with confirmation ────────────────────────────
  Future<void> _markAllRead(NotificationProvider provider) async {
    final unread = provider.unreadCount;
    if (unread == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Mark all as read?',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w900, color: AppColors.textDark)),
        content: Text(
            'All $unread notification${unread > 1 ? "s" : ""} will be marked as read.',
            style: GoogleFonts.nunito(color: AppColors.textMid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.nunito(color: AppColors.textLight)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Mark all read',
                style: GoogleFonts.nunito(
                    color: AppColors.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirm == true) await provider.markAllRead();
  }

  // ── Detail bottom sheet ────────────────────────────────────────
  void _showDetail(Map<String, dynamic> n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DetailSheet(notification: n),
    );
  }

  // ── Build ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final provider = NotificationProviderWidget.of(context);

    return AnimatedBuilder(
      animation: provider,
      builder: (context, _) {
        final all     = provider.notifications;
        final unread  = provider.unreadCount;
        final loading = provider.loading;
        final displayed =
            _showUnread ? all.where((n) => n['is_read'] != true).toList() : all;

        return Scaffold(
          backgroundColor: AppColors.background,
          body: Column(children: [
            _buildHeader(provider, unread),
            _buildFilters(all.length, unread),
            const Divider(height: 1, color: AppColors.border),
            Expanded(child: _buildList(provider, displayed, loading)),
          ]),
        );
      },
    );
  }

  // ── Header ─────────────────────────────────────────────────────
  Widget _buildHeader(NotificationProvider provider, int unread) {
    return Container(
      color: Colors.white,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 4,
        right: 16,
        bottom: 12,
      ),
      child: Row(children: [
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.chevron_left,
              color: AppColors.textMid, size: 28),
        ),
        Expanded(
          child: Row(children: [
            Text('Notifications',
                style: GoogleFonts.nunito(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textDark)),
            if (unread > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: AppColors.danger,
                    borderRadius: BorderRadius.circular(20)),
                child: Text('$unread',
                    style: GoogleFonts.nunito(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w900)),
              ),
            ],
          ]),
        ),
        if (unread > 0)
          TextButton(
            onPressed: () => _markAllRead(provider),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10)),
            child: Text('Mark all read',
                style: GoogleFonts.nunito(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  // ── Filter: All / Unread ───────────────────────────────────────
  Widget _buildFilters(int allCount, int unreadCount) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(children: [
        _FilterChip(
          label: 'All',
          count: allCount,
          selected: !_showUnread,
          onTap: () => setState(() => _showUnread = false),
        ),
        const SizedBox(width: 8),
        _FilterChip(
          label: 'Unread',
          count: unreadCount,
          selected: _showUnread,
          onTap: () => setState(() => _showUnread = true),
        ),
      ]),
    );
  }

  // ── List ───────────────────────────────────────────────────────
  Widget _buildList(
    NotificationProvider provider,
    List<Map<String, dynamic>> displayed,
    bool loading,
  ) {
    if (loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primary));
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () async {
        await Future.delayed(const Duration(milliseconds: 400));
      },
      child: displayed.isEmpty
          ? _EmptyState(showUnread: _showUnread)
          : FadeTransition(
              opacity: _fadeAnim,
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: displayed.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final n = displayed[i];
                  return Dismissible(
                    key: Key(n['id'].toString()),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) =>
                        provider.deleteNotification(n['id'].toString()),
                    background: const _DeleteBackground(),
                    child: _NotificationCard(
                      notification: n,
                      onTap: () => _handleTap(provider, n),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  NOTIFICATION CARD
// ─────────────────────────────────────────────────────────────────
class _NotificationCard extends StatelessWidget {
  final Map<String, dynamic> notification;
  final VoidCallback onTap;

  const _NotificationCard({required this.notification, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final n      = notification;
    final isRead = n['is_read'] == true;
    final type   = n['type'] as String?;
    final color  = _notifColor(type);
    final body   = (n['body'] as String?) ?? '';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isRead ? Colors.white : color.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isRead ? AppColors.border : color.withValues(alpha: 0.25),
            width: isRead ? 1 : 1.5,
          ),
          boxShadow: isRead
              ? []
              : [
                  BoxShadow(
                    color: color.withValues(alpha: 0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon bubble
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: isRead ? 0.08 : 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_notifIcon(type), color: color, size: 20),
            ),
            const SizedBox(width: 12),

            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _notifLabel(type),
                        style: GoogleFonts.nunito(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: color,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    const Spacer(),
                    if (!isRead)
                      Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                  ]),
                  const SizedBox(height: 5),
                  Text(
                    n['title'] ?? '',
                    style: GoogleFonts.nunito(
                      fontWeight: isRead ? FontWeight.w600 : FontWeight.w800,
                      fontSize: 14,
                      color: AppColors.textDark,
                    ),
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        color: AppColors.textLight,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    _timeAgo(n['created_at'] as String?),
                    style: GoogleFonts.nunito(
                        fontSize: 11, color: AppColors.textLight),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textLight),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  SWIPE-TO-DELETE BACKGROUND
// ─────────────────────────────────────────────────────────────────
class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      decoration: BoxDecoration(
        color: AppColors.danger,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline, color: Colors.white, size: 22),
          SizedBox(height: 4),
          Text('Delete',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  DETAIL SHEET
// ─────────────────────────────────────────────────────────────────
class _DetailSheet extends StatelessWidget {
  final Map<String, dynamic> notification;

  const _DetailSheet({required this.notification});

  @override
  Widget build(BuildContext context) {
    final n     = notification;
    final type  = n['type'] as String?;
    final color = _notifColor(type);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        MediaQuery.of(context).viewInsets.bottom + 36,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),

          // Icon + type label
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_notifIcon(type), color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _notifLabel(type),
                style: GoogleFonts.nunito(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: color,
                    letterSpacing: 0.4),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          // Title + body (scrolls if the announcement is long)
          Flexible(
            child: SingleChildScrollView(
              child: type == 'announcement'
                  ? _AnnouncementContent(
                      announcementId: n['reference_id']?.toString(),
                      fallbackTitle: n['title'] as String? ?? '',
                      fallbackBody: n['body'] as String? ?? '',
                    )
                  : _TitleAndBody(
                      title: n['title'] as String? ?? '',
                      body: n['body'] as String? ?? '',
                    ),
            ),
          ),

          const SizedBox(height: 14),
          Text(
            _timeAgo(n['created_at'] as String?),
            style: GoogleFonts.nunito(fontSize: 12, color: AppColors.textLight),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  TITLE + BODY (plain text)
// ─────────────────────────────────────────────────────────────────
class _TitleAndBody extends StatelessWidget {
  final String title;
  final String body;

  const _TitleAndBody({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.nunito(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.textDark),
        ),
        if (body.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            body,
            style: GoogleFonts.nunito(
                fontSize: 14, color: AppColors.textMid, height: 1.65),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  ANNOUNCEMENT CONTENT — loads the real announcement from Supabase
//
//  • New notifications carry `reference_id` → fetched by id.
//  • Old notifications (no reference_id) → falls back to matching the
//    announcement title found inside the notification body.
//  • If nothing is found, the notification's own title/body are shown.
// ─────────────────────────────────────────────────────────────────
class _AnnouncementContent extends StatefulWidget {
  final String? announcementId;
  final String  fallbackTitle;
  final String  fallbackBody;

  const _AnnouncementContent({
    required this.announcementId,
    required this.fallbackTitle,
    required this.fallbackBody,
  });

  @override
  State<_AnnouncementContent> createState() => _AnnouncementContentState();
}

class _AnnouncementContentState extends State<_AnnouncementContent> {
  late final Future<Map<String, dynamic>?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>?> _load() async {
    final db = Supabase.instance.client;

    try {
      // Preferred: look up by id
      if (widget.announcementId != null) {
        return await db
            .from('announcements')
            .select('title, body, content')
            .eq('id', widget.announcementId!)
            .maybeSingle();
      }

      // Legacy: body looks like  "<title>" has been published. ...
      final match = RegExp(r'^"(.+)" has been').firstMatch(widget.fallbackBody);
      final title = match?.group(1);
      if (title == null) return null;

      return await db
          .from('announcements')
          .select('title, body, content')
          .eq('title', title)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
    } catch (_) {
      return null; // fall back to the notification's own text
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            ),
          );
        }

        final data    = snap.data;
        final title   = (data?['title']   as String?) ?? widget.fallbackTitle;
        final content = (data?['body'] as String?)?.trim().isNotEmpty == true
            ? data!['body'] as String
            : (data?['content'] as String?) ?? widget.fallbackBody;

        return _TitleAndBody(title: title, body: content);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  FILTER CHIP
// ─────────────────────────────────────────────────────────────────
class _FilterChip extends StatelessWidget {
  final String label;
  final int    count;
  final bool   selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: GoogleFonts.nunito(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.textMid)),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.25)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$count',
                  style: GoogleFonts.nunito(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: selected ? Colors.white : AppColors.textLight)),
            ),
          ],
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  EMPTY STATE
// ─────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final bool showUnread;
  const _EmptyState({required this.showUnread});

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      const SizedBox(height: 80),
      Center(
        child: Column(children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
                color: AppColors.background, shape: BoxShape.circle),
            child: Icon(
              showUnread
                  ? Icons.mark_email_read_outlined
                  : Icons.notifications_none_outlined,
              size: 40,
              color: AppColors.textLight,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            showUnread ? 'All caught up!' : 'No notifications yet',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: AppColors.textDark),
          ),
          const SizedBox(height: 6),
          Text(
            showUnread
                ? 'You have no unread notifications.'
                : "You'll be notified about new modules,\nseminars, and announcements.",
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
                fontSize: 13, color: AppColors.textLight, height: 1.5),
          ),
        ]),
      ),
    ]);
  }
}