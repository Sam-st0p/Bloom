import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../services/badge_service.dart';


final _supabase = Supabase.instance.client;


class AssessmentScreen extends StatefulWidget {
  final String moduleId;
  final String moduleTitle;
  final VoidCallback onComplete;


  const AssessmentScreen({
    super.key,
    required this.moduleId,
    required this.moduleTitle,
    required this.onComplete,
  });


  @override
  State<AssessmentScreen> createState() => _AssessmentScreenState();
}


class _AssessmentScreenState extends State<AssessmentScreen> {
  Map<String, dynamic>? _assessment;
  List<Map<String, dynamic>> _questions = [];
  bool _loading = true;
  bool _submitting = false;
  bool _done = false;


  // Current question index
  int _currentQ = 0;


  // Selected answers: questionId -> optionId (or text for short answer)
  final Map<String, String> _answers = {};
  // Text controllers for short answer questions — persists text across navigation
  final Map<String, TextEditingController> _textControllers = {};


  // Timer
  Timer?  _timer;
  int     _secondsLeft = 0;
  bool    _timerStarted = false;


  // Results
  double _score = 0;
  double _maxScore = 0;
  bool _passed = false;
  int? _previousAttempts;


  @override
  void initState() {
    super.initState();
    _load();
  }


  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _textControllers.values) { c.dispose(); }
    super.dispose();
  }


  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Get assessment for this module
      final assessments = await _supabase
          .from('assessments')
          .select('*')
          .eq('module_id', widget.moduleId)
          .eq('is_published', true)
          .limit(1);


      if ((assessments as List).isEmpty) {
        if (mounted) setState(() { _loading = false; _assessment = null; });
        return;
      }


      final assessment = assessments.first;


      // Get questions with options
      final questions = await _supabase
          .from('questions')
          .select('*, question_options(*)')
          .eq('assessment_id', assessment['id'])
          .order('sort_order');


      // Check previous attempts
      final userId = _supabase.auth.currentUser?.id;
      int prevAttempts = 0;
      if (userId != null) {
        final attempts = await _supabase
            .from('assessment_attempts')
            .select('id')
            .eq('assessment_id', assessment['id'])
            .eq('user_id', userId);
        prevAttempts = (attempts as List).length;
      }


      if (mounted) {
        setState(() {
          _assessment = assessment;
          _questions = _deepCastQuestions(questions as List);
          _previousAttempts = prevAttempts;
          _loading = false;
        });
        // FIX: the admin panel saves the limit as "time_limit_minutes"
        final timeLimitMins =
            (assessment['time_limit_minutes'] ?? assessment['time_limit']) as int?;
        if (timeLimitMins != null && timeLimitMins > 0) {
          _startTimer(timeLimitMins * 60);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }




  // Deep-cast helper — fixes nested question_options not showing
  List<Map<String, dynamic>> _deepCastQuestions(List raw) {
    return raw.map((q) {
      final qMap = Map<String, dynamic>.from(q as Map);
      final opts = qMap['question_options'];
      if (opts is List) {
        qMap['question_options'] = opts
            .map((o) => Map<String, dynamic>.from(o as Map))
            .toList();
      } else {
        qMap['question_options'] = <Map<String, dynamic>>[];
      }
      return qMap;
    }).toList();
  }


  void _startTimer(int totalSeconds) {
    _timer?.cancel();
    setState(() { _secondsLeft = totalSeconds; _timerStarted = true; });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_secondsLeft <= 0) {
        t.cancel();
        if (!_done && !_submitting) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Time is up! Submitting your assessment…',
                  style: TextStyle(color: Colors.white)),
              backgroundColor: Color(0xFFDC2626),
              duration: Duration(seconds: 3),
            ),
          );
          _submitAssessment();
        }
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }


  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }


  Future<void> _submitAssessment() async {
    _timer?.cancel();
    setState(() => _submitting = true);
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;


      // Calculate score
      double score = 0;
      double maxScore = 0;


      for (final q in _questions) {
        final pts = (q['points'] as num?)?.toDouble() ?? 1.0;
        final qType = (q['question_type'] ?? 'multiple_choice').toString().toLowerCase();
        final isShortAnswer = qType == 'short_answer' || qType == 'essay';


        // Short answer questions are manually graded — exclude from auto-score
        if (isShortAnswer) continue;


        maxScore += pts;
        final selectedOptionId = _answers[q['id'].toString()];
        if (selectedOptionId != null) {
          final options = q['question_options'] as List? ?? [];
          final selected = options.firstWhere(
            (o) => o['id'].toString() == selectedOptionId,
            orElse: () => <String, dynamic>{},
          );
          if (selected['is_correct'] == true) {
            score += pts;
          }
        }
      }


      final passingScore = (_assessment?['passing_score'] as num?)?.toDouble() ?? 75.0;
      final passed = maxScore > 0 ? (score / maxScore * 100) >= passingScore : false;
      // FIX: save the score as a PERCENTAGE (e.g. 80), not the raw points (e.g. 4)
      final scorePercent = maxScore > 0 ? (score / maxScore * 100).round() : 0;


      // Save attempt
      final attempt = await _supabase.from('assessment_attempts').insert({
        'user_id': userId,
        'assessment_id': _assessment!['id'],
        'attempt_number': (_previousAttempts ?? 0) + 1,
        'score': scorePercent,
        'max_score': maxScore,
        'passed': passed,
        'started_at': DateTime.now().toIso8601String(),
        'submitted_at': DateTime.now().toIso8601String(),
        'status': 'submitted',
      }).select().single();


      // Save individual answers
      for (final q in _questions) {
        final qId = q['id'].toString();
        final answer = _answers[qId];
        if (answer == null) continue;


        final qType = (q['question_type'] ?? 'multiple_choice').toString().toLowerCase();
        final isShortAnswer = qType == 'short_answer' || qType == 'essay';


        if (isShortAnswer) {
          // Save short answer text — manually graded by admin
          await _supabase.from('assessment_answers').insert({
            'attempt_id': attempt['id'],
            'question_id': q['id'],
            'text_answer': answer,
            'is_correct': null, // pending manual grading
            'points_earned': 0,
          });
        } else {
          final options = q['question_options'] as List? ?? [];
          final selected = options.firstWhere(
            (o) => o['id'].toString() == answer,
            orElse: () => <String, dynamic>{},
          );
          final isCorrect = selected['is_correct'] == true;
          final pts = (q['points'] as num?)?.toDouble() ?? 1.0;


          await _supabase.from('assessment_answers').insert({
            'attempt_id': attempt['id'],
            'question_id': q['id'],
            'selected_option_id': answer,
            'is_correct': isCorrect,
            'points_earned': isCorrect ? pts : 0,
          });
        }
      }


      // If passed, update module progress to 100%
      if (passed) {
        await _supabase.from('module_progress').upsert({
          'user_id': userId,
          'module_id': widget.moduleId,
          'progress_percent': 100,
          'status': 'completed',
          'last_accessed_at': DateTime.now().toIso8601String(),
        }, onConflict: 'user_id,module_id');


        // Check and award badges
        await _checkAndAwardBadges(userId);
      }


      if (mounted) {
        setState(() {
          _score = score;
          _maxScore = maxScore;
          _passed = passed;
          _done = true;
          _submitting = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Submit error: $e');
      if (mounted) setState(() => _submitting = false);
    }
  }


  Future<void> _checkAndAwardBadges(String userId) async {
    // Shared logic lives in BadgeService so Library/Achievements use the same rules.
    final unlocked = await BadgeService.checkAndAward();
    if (unlocked.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('🏅 Badge unlocked: ${unlocked.join(', ')}'),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }


  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: const Center(child: CircularProgressIndicator(color: AppColors.primary)),
      );
    }


    if (_assessment == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.quiz_outlined, size: 48, color: AppColors.textLight),
                    const SizedBox(height: 12),
                    Text('No assessment available yet',
                        style: GoogleFonts.nunito(
                            color: AppColors.textLight, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('Check back later!',
                        style: GoogleFonts.nunito(color: AppColors.textLight, fontSize: 12)),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: widget.onComplete,
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                      child: Text('Back to Module',
                          style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }


    if (_done) return _buildResults();
    if (_questions.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: Column(
          children: [
            _buildHeader(),
            const Expanded(
              child: Center(child: Text('No questions found for this assessment.')),
            ),
          ],
        ),
      );
    }


    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(),
          _buildProgressBar(),
          Expanded(child: _buildQuestion()),
          _buildNavButtons(),
        ],
      ),
    );
  }


  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onComplete,
            icon: const Icon(Icons.chevron_left, color: AppColors.textMid),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_assessment?['title'] ?? 'Assessment',
                    style: GoogleFonts.nunito(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: AppColors.textDark)),
                Text(widget.moduleTitle,
                    style: GoogleFonts.nunito(fontSize: 12, color: AppColors.textLight)),
              ],
            ),
          ),
          if (!_done && _questions.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${_currentQ + 1}/${_questions.length}',
                  style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary)),
            ),
          if (_timerStarted && !_done) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: (_secondsLeft <= 60 ? const Color(0xFFDC2626) : AppColors.primary).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.timer_outlined, size: 13,
                    color: _secondsLeft <= 60 ? const Color(0xFFDC2626) : AppColors.primary),
                const SizedBox(width: 4),
                Text(_formatTime(_secondsLeft),
                    style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w800,
                        color: _secondsLeft <= 60 ? const Color(0xFFDC2626) : AppColors.primary)),
              ]),
            ),
          ],
        ],
      ),
    );
  }


  Widget _buildProgressBar() {
    final progress = _questions.isEmpty ? 0.0 : (_currentQ + 1) / _questions.length;
    return LinearProgressIndicator(
      value: progress,
      backgroundColor: AppColors.border,
      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
      minHeight: 4,
    );
  }


  Widget _buildQuestion() {
    final q = _questions[_currentQ];
    final qType = (q['question_type'] ?? 'multiple_choice').toString().toLowerCase();
    final isShortAnswer = qType == 'short_answer' || qType == 'essay';


    final options = List<Map<String, dynamic>>.from(q['question_options'] as List? ?? []);
    options.sort((a, b) => (a['sort_order'] as int? ?? 0).compareTo(b['sort_order'] as int? ?? 0));


    final selectedOptionId = _answers[q['id'].toString()];


    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          // Question type badge
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('Question ${_currentQ + 1}',
                  style: GoogleFonts.nunito(
                      fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isShortAnswer
                    ? Colors.orange.withValues(alpha: 0.1)
                    : Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isShortAnswer ? 'Short Answer' : (qType == 'true_false' ? 'True / False' : 'Multiple Choice'),
                style: GoogleFonts.nunito(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    color: isShortAnswer ? Colors.orange.shade700 : Colors.blue.shade700)),
            ),
          ]),
          const SizedBox(height: 14),
          Text(q['question_text'] ?? '',
              style: GoogleFonts.nunito(
                  fontSize: 16, fontWeight: FontWeight.w800,
                  color: AppColors.textDark, height: 1.4)),
          const SizedBox(height: 8),
          Text('${(q['points'] as num?) ?? 1} point${((q['points'] as num?) ?? 1) == 1 ? '' : 's'}',
              style: GoogleFonts.nunito(fontSize: 12, color: AppColors.textLight)),
          const SizedBox(height: 20),


          // ── Short answer ──────────────────────────────────────────
          if (isShortAnswer) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.edit_note_rounded, color: Colors.orange.shade600, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(
                    'Type your answer in the text box below. Your response will be reviewed and graded by the instructor.',
                    style: GoogleFonts.nunito(
                        fontSize: 12, color: Colors.orange.shade700, height: 1.5))),
                ]),
            ),
            const SizedBox(height: 16),
            Builder(builder: (context) {
              final qId = q['id'].toString();
              // Get or create a persistent controller for this question
              final ctrl = _textControllers.putIfAbsent(
                qId,
                () => TextEditingController(text: _answers[qId] ?? ''),
              );
              return TextField(
                controller: ctrl,
                maxLines: 5,
                onChanged: (v) {
                  if (v.trim().isNotEmpty) {
                    _answers[qId] = v.trim();
                  } else {
                    _answers.remove(qId);
                  }
                },
                style: GoogleFonts.nunito(fontSize: 14, color: AppColors.textDark),
                decoration: InputDecoration(
                  hintText: 'Write your answer here...',
                  hintStyle: GoogleFonts.nunito(color: AppColors.textLight, fontSize: 13),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.primary, width: 2)),
                  contentPadding: const EdgeInsets.all(14),
                ),
              );
            }),
          ]


          // ── Multiple choice / True-False ──────────────────────────
          else if (options.isEmpty) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.danger.withValues(alpha: 0.3))),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, color: AppColors.danger, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(
                  'No answer choices available for this question.',
                  style: GoogleFonts.nunito(fontSize: 13, color: AppColors.danger))),
              ]),
            ),
          ] else
            ...options.map((opt) {
              final optId = opt['id'].toString();
              final selected = selectedOptionId == optId;
              return GestureDetector(
                onTap: () => setState(() => _answers[q['id'].toString()] = optId),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primary.withValues(alpha: 0.08) : Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? AppColors.primary : AppColors.border,
                      width: selected ? 2 : 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 22, height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected ? AppColors.primary : Colors.transparent,
                          border: Border.all(
                            color: selected ? AppColors.primary : AppColors.border,
                            width: 2,
                          ),
                        ),
                        child: selected
                            ? const Icon(Icons.check, size: 14, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(opt['option_text'] ?? '',
                            style: GoogleFonts.nunito(
                                fontSize: 14,
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                color: selected ? AppColors.primary : AppColors.textDark)),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }


  Future<void> _confirmSubmit() async {
    // Count unanswered questions
    final unanswered = _questions
        .where((q) => !_answers.containsKey(q['id'].toString()))
        .length;


    if (unanswered > 0) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Submit Assessment?',
              style: GoogleFonts.nunito(fontWeight: FontWeight.w900, color: AppColors.textDark)),
          content: Text(
            'You have $unanswered unanswered question${unanswered == 1 ? '' : 's'}. '
            'Are you sure you want to submit?',
            style: GoogleFonts.nunito(fontSize: 14, color: AppColors.textMid, height: 1.5)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Go Back',
                  style: GoogleFonts.nunito(color: AppColors.textLight, fontWeight: FontWeight.w700))),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: Text('Submit Anyway',
                  style: GoogleFonts.nunito(color: Colors.white, fontWeight: FontWeight.w800))),
          ],
        ),
      );
      if (confirm != true) return;
    }


    _submitAssessment();
  }


  Widget _buildNavButtons() {
    final isLast = _currentQ == _questions.length - 1;
    final hasAnswer = _answers.containsKey(_questions[_currentQ]['id'].toString());
    final qType = (_questions[_currentQ]['question_type'] ?? 'multiple_choice').toString().toLowerCase();
    final isShortAnswer = qType == 'short_answer' || qType == 'essay';


    // Short answer questions are optional — don't block navigation
    final canProceed = hasAnswer || isShortAnswer;


    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (_currentQ > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _currentQ--),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.border, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text('← Previous',
                    style: GoogleFonts.nunito(
                        fontWeight: FontWeight.w700, color: AppColors.textMid)),
              ),
            ),
          if (_currentQ > 0) const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: !canProceed
                  ? null
                  : isLast
                      ? (_submitting ? null : _confirmSubmit)
                      : () => setState(() => _currentQ++),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor: AppColors.border,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(
                      isLast ? 'Submit Assessment' : 'Next →',
                      style: GoogleFonts.nunito(
                          fontWeight: FontWeight.w800, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildResults() {
    final pct = _maxScore > 0 ? (_score / _maxScore * 100).round() : 0;
    final passing = (_assessment?['passing_score'] as num?)?.toInt() ?? 75;


    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _passed
                          ? AppColors.primary.withValues(alpha: 0.1)
                          : AppColors.danger.withValues(alpha: 0.1),
                    ),
                    child: Center(
                      child: Text(_passed ? '🎉' : '📚',
                          style: const TextStyle(fontSize: 44)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(_passed ? 'Congratulations!' : 'Keep Practicing!',
                      style: GoogleFonts.nunito(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: _passed ? AppColors.primary : AppColors.danger)),
                  const SizedBox(height: 8),
                  Text(
                    _passed
                        ? 'You passed the assessment!'
                        : 'You need $passing% to pass. Try again!',
                    style: GoogleFonts.nunito(fontSize: 14, color: AppColors.textMid),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  AppCard(
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _ResultStat(label: 'Score', value: '$pct%',
                                color: _passed ? AppColors.primary : AppColors.danger),
                            _ResultStat(label: 'Correct',
                                value: '${_score.toInt()}/${_maxScore.toInt()}',
                                color: AppColors.info),
                            _ResultStat(label: 'Passing', value: '$passing%',
                                color: AppColors.accent),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: _maxScore > 0 ? _score / _maxScore : 0,
                            backgroundColor: AppColors.border,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                _passed ? AppColors.primary : AppColors.danger),
                            minHeight: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_passed)
                    AppCard(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text('✅', style: TextStyle(fontSize: 20)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Module Completed!',
                                    style: GoogleFonts.nunito(
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.textDark)),
                                Text('Your progress has been saved.',
                                    style: GoogleFonts.nunito(
                                        fontSize: 12, color: AppColors.textLight)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: widget.onComplete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text('Back to Module',
                          style: GoogleFonts.nunito(
                              fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
                    ),
                  ),
                  if (!_passed) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() {
                            _done = false;
                            _currentQ = 0;
                            _answers.clear();
                          });
                          _load();
                        },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.primary, width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text('Try Again',
                            style: GoogleFonts.nunito(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _ResultStat extends StatelessWidget {
  final String label, value;
  final Color color;
  const _ResultStat({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: GoogleFonts.nunito(
                fontSize: 22, fontWeight: FontWeight.w900, color: color)),
        Text(label,
            style: GoogleFonts.nunito(fontSize: 12, color: AppColors.textLight)),
      ],
    );
  }
}