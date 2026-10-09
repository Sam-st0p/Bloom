// lib/screens/badges_screen.dart
//
// BLOOM — Achievements screen: the designer's new layout (trophy header,
// "up next" badge card, richer badge tiles, certificate cards with inline
// Save/Share) wired to the real Supabase data layer and the real
// certificate-capture code from the previous badges_screen.dart.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import '../theme/app_theme.dart';
import '../services/badge_service.dart';

final _db = Supabase.instance.client;

String _fmtDate(String? iso) {
  if (iso == null) return '—';
  try {
    final d = DateTime.parse(iso).toLocal();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  } catch (_) { return iso; }
}

// ─────────────────────────────────────────────────────────────────
//  BADGES SCREEN
// ─────────────────────────────────────────────────────────────────
class BadgesScreen extends StatefulWidget {
  final int initialTab;
  const BadgesScreen({super.key, this.initialTab = 0});
  @override
  State<BadgesScreen> createState() => _BadgesScreenState();
}

class _BadgesScreenState extends State<BadgesScreen> {
  List<Map<String, dynamic>> _earnedBadges = [];
  List<Map<String, dynamic>> _allBadges = [];
  List<Map<String, dynamic>> _certificates = [];
  String _fullName = '';
  bool _loading = true;
  String? _error;
  late int _tab = widget.initialTab;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // MainShell re-uses this State when it only changes `initialTab`
  // (e.g. tapping a certificate notification while already on this tab).
  @override
  void didUpdateWidget(covariant BadgesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      setState(() => _tab = widget.initialTab);
    }
  }

  /// Runs one query and returns [fallback] if it fails, so one broken
  /// query (missing column, RLS) no longer leaves the whole screen
  /// spinning forever.
  Future<T> _safe<T>(String label, Future<T> Function() run, T fallback,
      List<String> errors) async {
    try {
      return await run();
    } catch (e) {
      debugPrint('[BadgesScreen] $label failed: $e');
      errors.add(label);
      return fallback;
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final uid = _db.auth.currentUser?.id;
    if (uid == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Please sign in to see your achievements.';
        });
      }
      return;
    }

    // Catch-up: award any badges the user already qualifies for.
    final unlocked = await BadgeService.checkAndAward();

    final errors = <String>[];
    final results = await Future.wait<dynamic>([
      _safe<dynamic>('earned badges', () => _db
          .from('student_badges')
          .select('*, badges(*)')
          .eq('user_id', uid)
          .order('awarded_at', ascending: false), const [], errors),
      _safe<dynamic>('badge list',
          () => _db.from('badges').select('*').order('name'), const [], errors),
      _safe<dynamic>('certificates', () => _db
          .from('certificates')
          .select('*')
          .eq('user_id', uid)
          .eq('is_revoked', false)
          .order('issued_at', ascending: false), const [], errors),
      _safe<dynamic>('profile',
          () => _db.from('profiles').select('full_name').eq('id', uid).maybeSingle(),
          null, errors),
    ]);

    if (!mounted) return;
    setState(() {
      _earnedBadges = List<Map<String, dynamic>>.from(results[0] as List);
      _allBadges = List<Map<String, dynamic>>.from(results[1] as List);
      _certificates = List<Map<String, dynamic>>.from(results[2] as List);
      _fullName =
          (results[3] as Map<String, dynamic>?)?['full_name'] as String? ?? '';
      _error = errors.length >= 3
          ? "Couldn't load achievements. Check your connection and pull down to retry."
          : null;
      _loading = false;
    });

    if (unlocked.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('🏅 Badge unlocked: ${unlocked.join(', ')}',
            style: GoogleFonts.nunito(fontSize: 13, color: Colors.white)),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  /// The badge row for an earned student_badges entry. Falls back to the
  /// full badge list if the embedded join came back empty.
  Map<String, dynamic> _badgeOf(Map<String, dynamic> sb) {
    final embedded = sb['badges'];
    if (embedded is Map<String, dynamic> && embedded.isNotEmpty) return embedded;
    final id = sb['badge_id']?.toString();
    return _allBadges.firstWhere((b) => b['id']?.toString() == id,
        orElse: () => <String, dynamic>{});
  }

  void _openBadge(Map<String, dynamic> badge,
      {required bool earned, String? awardedAt}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _BadgeDetailSheet(
        badge: badge,
        earned: earned,
        awardedAt: awardedAt,
      ),
    );
  }

  Set<String> get _earnedIds => _earnedBadges
      .map((b) => (b['badge_id'] ?? _badgeOf(b)['id'])?.toString() ?? '')
      .toSet();

  List<Map<String, dynamic>> get _lockedBadges {
    final ids = _earnedIds;
    return _allBadges
        .where((b) => !ids.contains(b['id']?.toString() ?? ''))
        .toList();
  }

  int get _total => _allBadges.isEmpty ? _earnedBadges.length : _allBadges.length;

  double get _pct =>
      _total == 0 ? 0 : (_earnedBadges.length / _total).clamp(0, 1).toDouble();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F9F0),
      body: Column(
        children: [
          _header(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : RefreshIndicator(
                    color: AppColors.primary,
                    onRefresh: _load,
                    child: _error != null
                        ? ListView(children: [
                            _EmptyState(
                              icon: Icons.cloud_off_rounded,
                              title: 'Something went wrong',
                              sub: _error!,
                            ),
                            Center(
                              child: TextButton.icon(
                                onPressed: _load,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Try again'),
                              ),
                            ),
                          ])
                        : (_tab == 0 ? _badgesTab() : _certsTab()),
                  ),
          ),
        ],
      ),
    );
  }

  // ---- Header with trophy ring ----------------------------------------------
  Widget _header() {
    final lockedCount = _lockedBadges.length;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Achievements',
                      style: GoogleFonts.nunito(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      )),
                  const SizedBox(height: 14),
                  Container(
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
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CustomPaint(
                                size: const Size(64, 64),
                                painter: _RingPainter(
                                    _pct, const Color(0xFFFFBA08)),
                              ),
                              const Icon(Icons.emoji_events_rounded,
                                  color: Color(0xFFFFBA08), size: 24),
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${_earnedBadges.length} of $_total badges earned',
                                  style: GoogleFonts.nunito(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  )),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  _miniStat(
                                      Icons.workspace_premium_rounded,
                                      '${_certificates.length} certificate${_certificates.length == 1 ? '' : 's'}',
                                      const Color(0xFFFFBA08)),
                                  const SizedBox(width: 14),
                                  _miniStat(
                                      Icons.flag_rounded,
                                      lockedCount == 0
                                          ? 'All unlocked!'
                                          : '$lockedCount to unlock',
                                      const Color(0xFFF4A261)),
                                ],
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
            const SizedBox(height: 14),
            Row(
              children: [
                _tabButton('Badges', Icons.military_tech_rounded, 0),
                _tabButton('Certificates', Icons.workspace_premium_rounded, 1),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(IconData icon, String text, Color iconColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: iconColor),
        const SizedBox(width: 5),
        Text(text,
            style: GoogleFonts.nunito(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            )),
      ],
    );
  }

  Widget _tabButton(String label, IconData icon, int index) {
    final active = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = index),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                  color: active ? Colors.white : Colors.transparent, width: 3),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: active
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.55)),
              const SizedBox(width: 6),
              Text(label,
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.55),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Badges tab -----------------------------------------------------------
  Widget _badgesTab() {
    if (_earnedBadges.isEmpty && _allBadges.isEmpty) {
      return ListView(children: const [
        _EmptyState(
          icon: Icons.military_tech_outlined,
          title: 'No achievements yet',
          sub: 'Complete assessments and modules to earn achievements',
        ),
      ]);
    }

    final locked = _lockedBadges;
    // `badges` is queried ordered by name, so this is simply the next one
    // alphabetically — there's no per-badge progress tracking to pick a
    // genuinely "nearest" one.
    final next = locked.isNotEmpty ? locked.first : null;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        if (next != null) ...[
          _NextBadgeCard(
            onTap: () => _openBadge(next, earned: false),
            name: next['name'] as String? ?? 'Badge',
            hint: (next['description'] as String?)?.trim().isNotEmpty == true
                ? next['description'] as String
                : 'Keep learning to unlock this badge.',
          ),
          const SizedBox(height: 18),
        ],
        if (_earnedBadges.isNotEmpty) ...[
          _sectionTitle(Icons.military_tech_rounded,
              'Earned (${_earnedBadges.length})', AppColors.primaryDark),
          const SizedBox(height: 10),
          _grid(_earnedBadges.map((sb) {
            final b = _badgeOf(sb);
            return _BadgeTile(
              name: b['name'] as String? ?? 'Badge',
              iconUrl: b['icon_url'] as String?,
              earned: true,
              awardedAt: sb['awarded_at']?.toString(),
              onTap: () => _openBadge(b,
                  earned: true, awardedAt: sb['awarded_at']?.toString()),
            );
          }).toList()),
        ],
        if (locked.isNotEmpty) ...[
          const SizedBox(height: 22),
          _sectionTitle(Icons.lock_outline_rounded,
              'Locked (${locked.length})', AppColors.textMid),
          const SizedBox(height: 10),
          _grid(locked.map((b) {
            return _BadgeTile(
              name: b['name'] as String? ?? 'Badge',
              iconUrl: b['icon_url'] as String?,
              earned: false,
              description: b['description'] as String?,
              onTap: () => _openBadge(b, earned: false),
            );
          }).toList()),
        ],
      ],
    );
  }

  Widget _sectionTitle(IconData icon, String text, Color color) => Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: GoogleFonts.nunito(
                  fontSize: 14, fontWeight: FontWeight.w800, color: color)),
        ],
      );

  Widget _grid(List<Widget> tiles) => GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.9,
        children: tiles,
      );

  // ---- Certificates tab -------------------------------------------------
  Widget _certsTab() {
    if (_certificates.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              children: [
                Icon(Icons.workspace_premium_outlined,
                    size: 48, color: Colors.grey[400]),
                const SizedBox(height: 12),
                Text('No certificates yet',
                    style: GoogleFonts.nunito(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[600])),
                const SizedBox(height: 6),
                Text('Attend seminars and complete modules to earn certificates',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey)),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _certificates.length,
      itemBuilder: (ctx, i) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: _CertCard(cert: _certificates[i], fullName: _fullName),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  "Up next" badge card (no fabricated progress — real name + hint only)
// ─────────────────────────────────────────────────────────────────
class _NextBadgeCard extends StatelessWidget {
  final String name;
  final String hint;
  final VoidCallback? onTap;
  const _NextBadgeCard({required this.name, required this.hint, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.info.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.workspace_premium_rounded,
                color: AppColors.info, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('UP NEXT',
                    style: GoogleFonts.nunito(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: AppColors.info,
                    )),
                const SizedBox(height: 3),
                Text(name,
                    style: GoogleFonts.nunito(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textDark,
                    )),
                if (hint.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(hint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textLight,
                      )),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.textLight),
        ],
      ),
    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  Badge tile — earned shows the real award date, locked shows the
//  real description instead of a fabricated progress bar
// ─────────────────────────────────────────────────────────────────
class _BadgeTile extends StatelessWidget {
  final String name;
  final String? iconUrl;
  final bool earned;
  final String? awardedAt;
  final String? description;
  final VoidCallback? onTap;
  const _BadgeTile({
    required this.name,
    this.iconUrl,
    required this.earned,
    this.awardedAt,
    this.description,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: earned ? Colors.white : const Color(0xFFFBFCFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: earned ? const Color(0xFFE9C46A) : AppColors.border,
          width: 1.5,
        ),
        boxShadow: earned
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8)]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: earned
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFFFF4D6), Color(0xFFF8E1A1)])
                      : null,
                  color: earned ? null : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Center(
                  child: (iconUrl ?? '').isNotEmpty
                      ? Image.network(iconUrl!,
                          width: 26,
                          height: 26,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                              Icons.military_tech_rounded,
                              size: 22,
                              color: earned
                                  ? AppColors.primaryDark
                                  : AppColors.textLight))
                      : Icon(Icons.military_tech_rounded,
                          size: 22,
                          color: earned
                              ? AppColors.primaryDark
                              : AppColors.textLight),
                ),
              ),
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: earned ? AppColors.primary : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: earned ? Colors.white : AppColors.border,
                        width: earned ? 2 : 1.5),
                  ),
                  child: Icon(earned ? Icons.check_rounded : Icons.lock_rounded,
                      size: 10,
                      color: earned ? Colors.white : AppColors.textLight),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.nunito(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: earned ? AppColors.primaryDark : AppColors.textMid,
                height: 1.15,
              )),
          const SizedBox(height: 3),
          if (earned)
            Text(_fmtDate(awardedAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textLight))
          else if ((description ?? '').isNotEmpty)
            Text(description!,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textLight)),
        ],
      ),
    ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  Certificate card — Save/Share are real, via CertificateViewerScreen
// ─────────────────────────────────────────────────────────────────
class _CertCard extends StatelessWidget {
  final Map<String, dynamic> cert;
  final String fullName;
  const _CertCard({required this.cert, required this.fullName});

  String get _refLabel {
    final t = cert['reference_type'] as String? ?? 'Program';
    return t.isEmpty ? 'Program' : '${t[0].toUpperCase()}${t.substring(1)}';
  }

  void _open(BuildContext context, {CertAutoAction action = CertAutoAction.none}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CertificateViewerScreen(
          cert: cert,
          fullName: fullName,
          autoAction: action,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFC8E6C9), width: 1.5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The whole header + code/issued row opens the viewer. The
          // Save/Share row below is a sibling, not nested inside this tap
          // target, so the two don't fight over the same tap.
          GestureDetector(
            onTap: () => _open(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [AppColors.primaryDark, AppColors.primary],
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.workspace_premium_outlined,
                            color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('BLOOM GAD · GADRC CvSU',
                                style: GoogleFonts.nunito(
                                  fontSize: 9,
                                  color: Colors.white60,
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w600,
                                )),
                            Text('Certificate of $_refLabel',
                                style: GoogleFonts.nunito(
                                  fontSize: 13,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                )),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F5E9),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFC8E6C9)),
                        ),
                        child: Text(cert['certificate_code'] as String? ?? '—',
                            style: GoogleFonts.nunito(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                              letterSpacing: 1,
                            )),
                      ),
                      const Spacer(),
                      Text('Issued ${_fmtDate(cert['issued_at'] as String?)}',
                          style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: _certAction(
                    'Save',
                    Icons.download_rounded,
                    AppColors.primary,
                    AppColors.primary.withValues(alpha: 0.12),
                    () => _open(context, action: CertAutoAction.save),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _certAction(
                    'Share',
                    Icons.share_outlined,
                    AppColors.primaryDark,
                    AppColors.background,
                    () => _open(context, action: CertAutoAction.share),
                    bordered: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _certAction(String label, IconData icon, Color fg, Color bg,
      VoidCallback onTap, {bool bordered = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: bordered
              ? Border.all(color: AppColors.border, width: 1.5)
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 7),
            Text(label,
                style: GoogleFonts.nunito(
                    fontSize: 13, fontWeight: FontWeight.w800, color: fg)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  Trophy ring painter
// ─────────────────────────────────────────────────────────────────
class _RingPainter extends CustomPainter {
  final double pct; // 0..1
  final Color color;
  _RingPainter(this.pct, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 7.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - stroke) / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.5708,
      6.2832 * pct,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.pct != pct || old.color != color;
}

// ─────────────────────────────────────────────────────────────────
//  CERTIFICATE VIEWER SCREEN (unchanged capture/save/share logic from the
//  previous screen, plus an optional autoAction so list-level Save/Share
//  buttons can trigger it once the certificate has actually rendered)
// ─────────────────────────────────────────────────────────────────
enum CertAutoAction { none, save, share }

class CertificateViewerScreen extends StatefulWidget {
  final Map<String, dynamic> cert;
  final String fullName;
  final CertAutoAction autoAction;
  const CertificateViewerScreen({
    super.key,
    required this.cert,
    required this.fullName,
    this.autoAction = CertAutoAction.none,
  });
  @override State<CertificateViewerScreen> createState() => _CertificateViewerScreenState();
}

class _CertificateViewerScreenState extends State<CertificateViewerScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoAction != CertAutoAction.none) {
      // Wait for the first frame (so the RepaintBoundary actually has
      // something painted to capture), plus a short buffer for the
      // certificate's custom fonts to finish loading.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          if (widget.autoAction == CertAutoAction.save) {
            _saveToGallery();
          } else if (widget.autoAction == CertAutoAction.share) {
            _shareImage();
          }
        });
      });
    }
  }

  String get _certTitle {
    final refType = widget.cert['reference_type'] as String? ?? 'manual';
    return refType == 'manual'
        ? 'Certificate of Achievement'
        : 'Certificate of ${refType[0].toUpperCase()}${refType.substring(1)}';
  }
  String get _recipientName => widget.fullName.isNotEmpty ? widget.fullName : 'Recipient';
  String get _code     => widget.cert['certificate_code'] as String? ?? '—';
  String get _issued   => _fmtDate(widget.cert['issued_at'] as String?);
  String get _bodyText => widget.cert['body_text'] as String? ??
      'has successfully completed the requirements of the BLOOM GAD e-Learning Program and is hereby awarded this certificate in recognition of outstanding participation and commitment to Gender and Development advocacy.';
  String get _sig1Name  => widget.cert['sig1_name']  as String? ?? 'GAD Coordinator';
  String get _sig1Title => widget.cert['sig1_title'] as String? ?? 'Cavite State University';
  String get _sig2Name  => widget.cert['sig2_name']  as String? ?? 'GADRC Director';
  String get _sig2Title => widget.cert['sig2_title'] as String? ?? 'Cavite State University';

  Color get _themeColor {
    final c = widget.cert['theme_color'] as String?;
    if (c == null) return AppColors.primary;
    try { return Color(int.parse(c.replaceFirst('#', '0xff'))); }
    catch (_) { return AppColors.primary; }
  }

  /// Capture the RepaintBoundary as a high-res PNG
  Future<Uint8List?> _capturePng() async {
    final boundary = _repaintKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image    = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  /// Save certificate PNG to Android gallery
  Future<void> _saveToGallery() async {
    setState(() => _saving = true);
    try {
      final bytes = await _capturePng();
      if (bytes == null) throw Exception('Could not capture certificate.');

      final fileName =
          'BLOOM_GAD_${_code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.png';

      // Write to temp file then save to gallery
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);
      await Gal.putImage(file.path);

      // Clean up temp file
      await file.delete();

      if (mounted) _showSnack('✓ Certificate saved to gallery!', isSuccess: true);
    } catch (e) {
      if (mounted) _showSnack('Error: $e', isSuccess: false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Share certificate image via Android share sheet
  Future<void> _shareImage() async {
    try {
      final bytes = await _capturePng();
      if (bytes == null) throw Exception('Could not capture certificate.');

      final fileName =
          'BLOOM_GAD_${_code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.png';

      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          subject: _certTitle,
          text: 'My BLOOM GAD Certificate — $_code',
        ),
      );

      // Clean up temp file after sharing
      await file.delete();
    } catch (e) {
      if (mounted) _showSnack('Error sharing: $e', isSuccess: false);
    }
  }

  void _showSnack(String msg, {required bool isSuccess}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.nunito(fontSize: 13, color: Colors.white)),
      backgroundColor: isSuccess ? AppColors.primary : const Color(0xFFDC2626),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final certW   = screenW - 32;
    final certH   = certW / 0.85;

    return Scaffold(
      backgroundColor: AppColors.primaryDark,
      appBar: AppBar(
        backgroundColor: AppColors.primaryDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(_certTitle,
            style: GoogleFonts.nunito(
                fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        actions: [
          // Share button
          if (!_saving)
            IconButton(
              tooltip: 'Share',
              onPressed: _shareImage,
              icon: const Icon(Icons.share_outlined, color: Colors.white, size: 20),
            ),
          // Save to gallery button
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
            )
          else
            TextButton.icon(
              onPressed: _saveToGallery,
              icon: const Icon(Icons.download_rounded, size: 18, color: Colors.white),
              label: Text('Save',
                  style: GoogleFonts.nunito(
                      fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8, maxScale: 4.0,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: RepaintBoundary(
              key: _repaintKey,
              child: SizedBox(
                width: certW, height: certH,
                child: CertificateCard(
                  certTitle: _certTitle, name: _recipientName,
                  code: _code, issued: _issued, bodyText: _bodyText,
                  sig1Name: _sig1Name, sig1Title: _sig1Title,
                  sig2Name: _sig2Name, sig2Title: _sig2Title,
                  themeColor: _themeColor,
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Container(
        color: AppColors.primaryDark,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.pinch_outlined, color: Colors.white54, size: 16),
          const SizedBox(width: 6),
          Text('Pinch to zoom  ·  Tap Save to download',
              style: GoogleFonts.nunito(fontSize: 12, color: Colors.white54)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  CERTIFICATE CARD (unchanged)
// ─────────────────────────────────────────────────────────────────
class CertificateCard extends StatelessWidget {
  final String certTitle, name, code, issued, bodyText,
               sig1Name, sig1Title, sig2Name, sig2Title;
  final Color themeColor;
  const CertificateCard({super.key,
    required this.certTitle, required this.name,
    required this.code,      required this.issued,
    this.bodyText  = 'has successfully completed the requirements of the BLOOM GAD e-Learning Program and is hereby awarded this certificate in recognition of outstanding participation and commitment to Gender and Development advocacy.',
    this.sig1Name  = 'GAD Coordinator',
    this.sig1Title = 'Cavite State University',
    this.sig2Name  = 'GADRC Director',
    this.sig2Title = 'Cavite State University',
    this.themeColor = AppColors.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFFFAFDF6), Color(0xFFF0F7EC)],
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: themeColor, width: 6),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.25), blurRadius: 24,
            offset: const Offset(0, 8))],
      ),
      child: Stack(children: [
        Positioned.fill(child: Padding(
          padding: const EdgeInsets.all(8),
          child: DecoratedBox(decoration: BoxDecoration(
              border: Border.all(color: themeColor.withValues(alpha: 0.2), width: 1),
              borderRadius: BorderRadius.circular(4))),
        )),
        ..._corners(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(children: [
                Text('CAVITE STATE UNIVERSITY',
                    style: GoogleFonts.nunito(fontSize: 10, fontWeight: FontWeight.w800,
                        color: themeColor, letterSpacing: 2.5),
                    textAlign: TextAlign.center),
                const SizedBox(height: 2),
                Text('Gender and Development Resource Center (GADRC)',
                    style: GoogleFonts.nunito(fontSize: 8, color: Colors.grey[600], letterSpacing: 0.5),
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Divider(color: themeColor.withValues(alpha: 0.4), thickness: 1)),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Container(
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: themeColor, width: 1.5)),
                      child: Icon(Icons.eco_outlined, size: 12, color: themeColor))),
                  Expanded(child: Divider(color: themeColor.withValues(alpha: 0.4), thickness: 1)),
                ]),
              ]),
              Column(children: [
                Text(certTitle,
                    style: GoogleFonts.playfairDisplay(fontSize: 22, fontWeight: FontWeight.w700,
                        color: AppColors.primaryDark),
                    textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text('THIS IS TO CERTIFY THAT',
                    style: GoogleFonts.nunito(fontSize: 7, color: Colors.grey[500], letterSpacing: 3),
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Color(0xFFC8E6C9), width: 2))),
                  child: Text(name,
                      style: GoogleFonts.playfairDisplay(fontSize: 26, fontWeight: FontWeight.w700,
                          color: themeColor, fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center)),
                const SizedBox(height: 8),
                Text(bodyText,
                    style: GoogleFonts.nunito(fontSize: 8, color: Colors.grey[600], height: 1.5),
                    textAlign: TextAlign.center, overflow: TextOverflow.clip),
              ]),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: CertSignatureBlock(title: sig1Name, sub: sig1Title)),
                  Flexible(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: themeColor, width: 2),
                          color: const Color(0xFFE8F5E9)),
                      child: Icon(Icons.verified_outlined, size: 16, color: themeColor)),
                    const SizedBox(height: 3),
                    Text('Certificate Code',
                        style: GoogleFonts.nunito(fontSize: 6, color: Colors.grey, letterSpacing: 0.5),
                        textAlign: TextAlign.center),
                    Text(code,
                        style: GoogleFonts.nunito(fontSize: 8, fontWeight: FontWeight.w800,
                            color: themeColor, letterSpacing: 1),
                        textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
                    Text('Issued: $issued',
                        style: GoogleFonts.nunito(fontSize: 6, color: Colors.grey[500]),
                        textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
                  ])),
                  Expanded(child: CertSignatureBlock(title: sig2Name, sub: sig2Title)),
                ],
              ),
            ],
          ),
        ),
      ]),
    );
  }

  List<Widget> _corners() {
    const size = 16.0;
    return [
      Positioned(top: 14, left: 14,     child: CertCorner(color: themeColor, size: size, flip: false, vert: false)),
      Positioned(top: 14, right: 14,    child: CertCorner(color: themeColor, size: size, flip: true,  vert: false)),
      Positioned(bottom: 14, left: 14,  child: CertCorner(color: themeColor, size: size, flip: false, vert: true)),
      Positioned(bottom: 14, right: 14, child: CertCorner(color: themeColor, size: size, flip: true,  vert: true)),
    ];
  }
}

class CertCorner extends StatelessWidget {
  final Color color;
  final double size;
  final bool flip, vert;
  const CertCorner({super.key, required this.color, required this.size, required this.flip, required this.vert});
  @override
  Widget build(BuildContext context) => Transform.flip(
    flipX: flip, flipY: vert,
    child: SizedBox(width: size, height: size,
        child: CustomPaint(painter: CertCornerPainter(color))));
}

class CertCornerPainter extends CustomPainter {
  final Color color;
  const CertCornerPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke;
    canvas.drawLine(Offset.zero, Offset(size.width, 0), p);
    canvas.drawLine(Offset.zero, Offset(0, size.height), p);
  }
  @override bool shouldRepaint(_) => false;
}

class CertSignatureBlock extends StatelessWidget {
  final String title, sub;
  const CertSignatureBlock({super.key, required this.title, required this.sub});
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      Divider(color: AppColors.primaryDark, thickness: 1),
      Text(title,
          style: GoogleFonts.nunito(fontSize: 7, fontWeight: FontWeight.w700,
              color: AppColors.primaryDark, letterSpacing: 0.3),
          textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
      Text(sub,
          style: GoogleFonts.nunito(fontSize: 6, color: Colors.grey),
          textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
    ]);
}

// ─────────────────────────────────────────────────────────────────
//  BADGE DETAIL SHEET — opens when a badge tile is tapped. Earned badges
//  show the award date; locked badges show the real requirement(s) from
//  `badge_criteria` with the student's actual progress.
// ─────────────────────────────────────────────────────────────────
class _BadgeDetailSheet extends StatefulWidget {
  final Map<String, dynamic> badge;
  final bool earned;
  final String? awardedAt;
  const _BadgeDetailSheet({
    required this.badge,
    required this.earned,
    this.awardedAt,
  });

  @override
  State<_BadgeDetailSheet> createState() => _BadgeDetailSheetState();
}

class _BadgeDetailSheetState extends State<_BadgeDetailSheet> {
  List<BadgeRequirement>? _reqs;

  @override
  void initState() {
    super.initState();
    final id = widget.badge['id']?.toString();
    if (!widget.earned && id != null) {
      BadgeService.requirementsFor(id).then((r) {
        if (mounted) setState(() => _reqs = r);
      });
    } else {
      _reqs = const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.badge['name'] as String? ?? 'Badge';
    final desc = (widget.badge['description'] as String? ?? '').trim();
    final iconUrl = widget.badge['icon_url'] as String?;
    final earned = widget.earned;

    final fallbackIcon = Icon(
      earned ? Icons.emoji_events_rounded : Icons.lock_rounded,
      size: 40,
      color: earned ? const Color(0xFFF59E0B) : AppColors.textLight,
    );

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 12, 24, 24 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 20),
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              gradient: earned
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFFF4D6), Color(0xFFF8E1A1)])
                  : null,
              color: earned ? null : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                  color: earned ? const Color(0xFFE9C46A) : AppColors.border,
                  width: 2),
            ),
            child: Center(
              child: (iconUrl ?? '').isNotEmpty
                  ? Opacity(
                      opacity: earned ? 1 : 0.45,
                      child: Image.network(iconUrl!,
                          width: 50,
                          height: 50,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => fallbackIcon),
                    )
                  : fallbackIcon,
            ),
          ),
          const SizedBox(height: 14),
          Text(name,
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textDark)),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(desc,
                textAlign: TextAlign.center,
                style: GoogleFonts.nunito(
                    fontSize: 13, color: AppColors.textMid, height: 1.4)),
          ],
          const SizedBox(height: 16),
          if (earned)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(10)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle_rounded,
                    size: 16, color: AppColors.primary),
                const SizedBox(width: 6),
                Text('Earned on ${_fmtDate(widget.awardedAt)}',
                    style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryDark)),
              ]),
            )
          else
            _requirements(),
        ],
      ),
    );
  }

  Widget _requirements() {
    if (_reqs == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primary)),
      );
    }
    if (_reqs!.isEmpty) {
      return Text('Keep learning to unlock this badge.',
          style: GoogleFonts.nunito(fontSize: 12, color: AppColors.textLight));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HOW TO UNLOCK',
            style: GoogleFonts.nunito(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: AppColors.info)),
        const SizedBox(height: 8),
        for (final r in _reqs!) ...[
          Row(children: [
            Expanded(
              child: Text(r.label,
                  style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark)),
            ),
            if (r.current != null)
              Text('${r.current!.clamp(0, r.threshold)} / ${r.threshold}',
                  style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
          ]),
          if (r.current != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: r.progress,
                minHeight: 8,
                backgroundColor: const Color(0xFFEFF3EC),
                color: AppColors.primary,
              ),
            ),
          ],
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//  EMPTY STATE
// ─────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  const _EmptyState({required this.icon, required this.title, required this.sub});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(padding: const EdgeInsets.all(40),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 48, color: Colors.grey[400]),
        const SizedBox(height: 12),
        Text(title, style: GoogleFonts.nunito(
            fontSize: 16, fontWeight: FontWeight.w700, color: Colors.grey[600])),
        const SizedBox(height: 6),
        Text(sub, textAlign: TextAlign.center,
            style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey)),
      ]),
    ),
  );
}