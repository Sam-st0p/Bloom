// lib/services/badge_service.dart
//
// One place that decides which badges a user has earned and awards them.
//
// Before, badge awarding lived only inside AssessmentScreen and only ran
// after a *passed assessment*. Completing a module from the Library never
// awarded anything, users who already qualified before the feature existed
// never got their badges, and every error was swallowed silently — so the
// Achievements screen always looked "broken".
//
// Now it's called from:
//   - AssessmentScreen, after a passed assessment
//   - LibraryScreen, after a module reaches 100%
//   - BadgesScreen, every time it loads (catch-up for existing users)

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BadgeService {
  static SupabaseClient get _db => Supabase.instance.client;

  /// Checks every row in `badge_criteria` against the user's real progress
  /// and inserts any missing rows into `student_badges`.
  ///
  /// Returns the names of the badges newly awarded during this call
  /// (empty list if none), so the UI can show a "badge unlocked" message.
  static Future<List<String>> checkAndAward() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];

    // 1) Preferred: let the database award badges (award_my_badges() from
    //    supabase_badges_auto_award.sql). Not affected by RLS.
    try {
      final res = await _db.rpc('award_my_badges');
      final names = (res is List)
          ? res
              .map((e) => e is Map ? e.values.first.toString() : e.toString())
              .toList()
          : <String>[];
      debugPrint('[BadgeService] award_my_badges -> $names');
      return names;
    } catch (e) {
      debugPrint('[BadgeService] award_my_badges RPC not available, '
          'falling back to in-app check: $e');
    }

    // 2) Fallback: check in the app.
    final newlyAwarded = <String>[];

    try {
      final criteria = List<Map<String, dynamic>>.from(
        await _db.from('badge_criteria').select('*'),
      );
      if (criteria.isEmpty) {
        debugPrint('[BadgeService] badge_criteria is empty — nothing to award. '
            'Add rows to badge_criteria for each badge.');
        return [];
      }

      // Badge names, for the "unlocked" message (separate query so we don't
      // depend on a foreign key between badge_criteria and badges).
      final names = <String, String>{};
      try {
        final rows = await _db.from('badges').select('id, name');
        for (final r in rows as List) {
          names[r['id'].toString()] = r['name']?.toString() ?? 'Badge';
        }
      } catch (_) {}

      final earned = await _db
          .from('student_badges')
          .select('badge_id')
          .eq('user_id', userId);
      final earnedIds =
          Set<String>.from((earned as List).map((e) => e['badge_id'].toString()));

      // Load each counter lazily and only once.
      final counts = <String, int>{};
      Future<int> count(String type) async {
        if (counts.containsKey(type)) return counts[type]!;
        final v = await _countFor(type, userId);
        counts[type] = v;
        return v;
      }

      for (final c in criteria) {
        final badgeId = c['badge_id']?.toString();
        if (badgeId == null || earnedIds.contains(badgeId)) continue;

        final type = (c['criteria_type'] as String? ?? '').trim().toLowerCase();
        // threshold may come back as int, double or string depending on column type
        final threshold = int.tryParse('${c['threshold_value'] ?? 1}') ??
            (c['threshold_value'] as num?)?.toInt() ??
            1;

        final current = await count(type);
        if (current < 0) continue; // unknown/unsupported type
        if (current < threshold) continue;

        try {
          await _db.from('student_badges').insert({
            'user_id': userId,
            'badge_id': badgeId,
            'awarded_at': DateTime.now().toUtc().toIso8601String(),
          });
          earnedIds.add(badgeId);
          newlyAwarded.add(names[badgeId] ?? 'New badge');
        } on PostgrestException catch (e) {
          if (e.code == '23505') {
            earnedIds.add(badgeId); // already awarded (unique constraint) — fine
          } else {
            // Most common cause: RLS policy does not allow the student to
            // insert into student_badges. See supabase_badges_fix.sql.
            debugPrint('[BadgeService] insert into student_badges failed: '
                '${e.code} ${e.message}');
          }
        }
      }
    } catch (e) {
      debugPrint('[BadgeService] checkAndAward error: $e');
    }

    return newlyAwarded;
  }

  /// Requirements for one badge with the user's current progress, used by
  /// the badge detail sheet. Empty list if the badge has no criteria.
  static Future<List<BadgeRequirement>> requirementsFor(String badgeId) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];
    try {
      final rows = await _db
          .from('badge_criteria')
          .select('*')
          .eq('badge_id', badgeId);
      final out = <BadgeRequirement>[];
      for (final c in rows as List) {
        final type = (c['criteria_type'] as String? ?? '').trim().toLowerCase();
        final threshold = int.tryParse('${c['threshold_value'] ?? 1}') ??
            (c['threshold_value'] as num?)?.toInt() ??
            1;
        final current = await _countFor(type, userId);
        out.add(BadgeRequirement(
          type: type,
          threshold: threshold,
          current: current < 0 ? null : current,
        ));
      }
      return out;
    } catch (e) {
      debugPrint('[BadgeService] requirementsFor failed: $e');
      return [];
    }
  }

  /// Returns the user's current value for a criteria type, or -1 if the
  /// type isn't supported.
  static Future<int> _countFor(String type, String userId) async {
    // Same flexible matching as the SQL function (e.g. "complete_modules").
    if (type.contains('perfect')) {
      type = 'perfect_score';
    } else if (type.contains('module')) {
      type = 'modules_completed';
    } else if (type.contains('assessment') || type.contains('quiz')) {
      type = 'assessments_passed';
    } else if (type.contains('certificate')) {
      type = 'certificates_earned';
    } else if (type.contains('evaluat')) {
      type = 'seminars_evaluated';
    } else if (type.contains('seminar')) {
      type = 'seminars_joined';
    } else if (type.contains('forum')) {
      type = 'forum_posts';
    }
    try {
      switch (type) {
        case 'modules_completed':
        case 'module_completed':
        case 'modules':
          // Done = status 'completed' OR progress reached 100%
          final r = await _db
              .from('module_progress')
              .select('module_id, status, progress_percent')
              .eq('user_id', userId);
          return (r as List)
              .where((m) =>
                  m['status'] == 'completed' ||
                  ((m['progress_percent'] as num?) ?? 0) >= 100)
              .map((m) => m['module_id'].toString())
              .toSet()
              .length;

        case 'assessments_passed':
        case 'assessment_passed':
        case 'assessments':
          final r = await _db
              .from('assessment_attempts')
              .select('assessment_id')
              .eq('user_id', userId)
              .eq('passed', true);
          // count distinct assessments, not attempts
          return (r as List).map((e) => e['assessment_id'].toString()).toSet().length;

        case 'perfect_score':
          final r = await _db
              .from('assessment_attempts')
              .select('assessment_id, score, max_score')
              .eq('user_id', userId);
          return (r as List)
              .where((a) {
                final max = (a['max_score'] as num?) ?? 0;
                final score = (a['score'] as num?) ?? 0;
                return max > 0 && score >= max;
              })
              .map((a) => a['assessment_id'].toString())
              .toSet()
              .length;

        case 'certificates_earned':
        case 'certificates':
          final r = await _db
              .from('certificates')
              .select('id')
              .eq('user_id', userId)
              .eq('is_revoked', false);
          return (r as List).length;

        case 'seminars_registered':
        case 'seminars_joined':
        case 'seminars':
          final r = await _db
              .from('seminar_registrations')
              .select('id')
              .eq('user_id', userId)
              .neq('status', 'cancelled');
          return (r as List).length;

        case 'seminars_evaluated':
        case 'evaluations':
          final r = await _db
              .from('seminar_evaluations')
              .select('id')
              .eq('user_id', userId);
          return (r as List).length;

        case 'forum_posts':
          final posts = await _db
              .from('forum_posts')
              .select('id')
              .eq('user_id', userId);
          final replies = await _db
              .from('forum_replies')
              .select('id')
              .eq('user_id', userId);
          return (posts as List).length + (replies as List).length;

        default:
          debugPrint('[BadgeService] unsupported criteria_type "$type"');
          return -1;
      }
    } catch (e) {
      debugPrint('[BadgeService] count for "$type" failed: $e');
      return -1;
    }
  }
}

class BadgeRequirement {
  final String type;
  final int threshold;
  final int? current; // null = type not tracked by the app

  const BadgeRequirement({
    required this.type,
    required this.threshold,
    required this.current,
  });

  double get progress =>
      current == null || threshold <= 0 ? 0 : (current! / threshold).clamp(0, 1).toDouble();

  String get label {
    final n = threshold;
    String plural(String word) => n == 1 ? word : '${word}s';
    switch (type) {
      case 'modules_completed':
      case 'module_completed':
      case 'modules':
        return 'Complete $n ${plural('module')}';
      case 'assessments_passed':
      case 'assessment_passed':
      case 'assessments':
        return 'Pass $n ${plural('assessment')}';
      case 'perfect_score':
        return 'Get a perfect score on $n ${plural('assessment')}';
      case 'seminars_attended':
        return 'Attend $n ${plural('seminar')}';
      case 'certificates_earned':
      case 'certificates':
        return 'Earn $n ${plural('certificate')}';
      case 'seminars_registered':
      case 'seminars_joined':
      case 'seminars':
        return 'Join $n ${plural('seminar')}';
      case 'seminars_evaluated':
      case 'evaluations':
        return 'Submit $n seminar ${plural('evaluation')}';
      case 'forum_posts':
      case 'forum':
        return n == 1 ? 'Make 1 forum post or reply' : 'Make $n forum posts or replies';
      default:
        return type.isEmpty ? 'Special requirement' : type.replaceAll('_', ' ');
    }
  }
}