// lib/screens/profile_screen.dart
// BLOOM GAD Mobile App — Profile Screen

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/common_widgets.dart';
import 'badges_screen.dart' show CertificateViewerScreen, CertificateCard;
import 'help_screen.dart';

final _supabase = Supabase.instance.client;

// ─────────────────────────────────────────────────────────────────────────────
//  CVSU DEPARTMENT / COURSE DATA
// ─────────────────────────────────────────────────────────────────────────────
const Map<String, List<String>> kCvsuDeptCourses = {
  'College of Agriculture, Food Technology and Forestry': [
    'BS Agriculture', 'BS Food Technology', 'BS Forestry',
    'BS Agricultural Engineering',
  ],
  'College of Arts and Sciences': [
    'AB Communication', 'AB English Language Studies', 'BS Biology',
    'BS Mathematics', 'BS Psychology', 'BS Statistics',
  ],
  'College of Business Administration': [
    'BS Accountancy', 'BS Business Administration',
    'BS Entrepreneurship', 'BS Office Administration',
  ],
  'College of Criminal Justice Education': ['BS Criminology'],
  'College of Education': [
    'Bachelor of Elementary Education', 'Bachelor of Secondary Education',
    'Bachelor of Physical Education', 'Bachelor of Early Childhood Education',
    'BS Industrial Technology Education',
  ],
  'College of Engineering and Information Technology': [
    'BS Civil Engineering', 'BS Computer Engineering',
    'BS Electrical Engineering', 'BS Electronics Engineering',
    'BS Mechanical Engineering', 'BS Information Technology',
    'BS Computer Science',
  ],
  'College of Fisheries and Ocean Sciences': ['BS Fisheries'],
  'College of Hospitality and Institutional Management': [
    'BS Hotel and Restaurant Management', 'BS Tourism Management',
  ],
  'College of Nursing': ['BS Nursing'],
  'College of Veterinary Medicine and Biomedical Sciences': [
    'Doctor of Veterinary Medicine', 'BS Veterinary Technology',
  ],
  'Graduate School': [
    'Master of Arts in Education', 'Master in Business Administration',
    'Master of Science in Agriculture', 'Doctor of Philosophy',
  ],
};

const List<String> kYearLevels = [
  '1st Year', '2nd Year', '3rd Year', '4th Year', '5th Year',
];

// ─────────────────────────────────────────────────────────────────────────────
//  VALIDATORS
// ─────────────────────────────────────────────────────────────────────────────
String? _validateName(String? v, String field) {
  if (v == null || v.trim().isEmpty) return '$field is required.';
  final t = v.trim();
  if (t.length < 2)  return '$field must be at least 2 characters.';
  if (t.length > 50) return '$field must be 50 characters or less.';
  if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'\-]+$").hasMatch(t)) {
    return '$field may only contain letters, spaces, hyphens and apostrophes.';
  }
  return null;
}

String? _validateStudentId(String? v) {
  if (v == null || v.trim().isEmpty) return 'Student ID is required.';
  final t = v.trim();
  if (t.length < 5)  return 'Student ID must be at least 5 characters.';
  if (t.length > 20) return 'Student ID must be 20 characters or less.';
  if (!RegExp(r'^[a-zA-Z0-9\-]+$').hasMatch(t)) {
    return 'Student ID may only contain letters, numbers and hyphens.';
  }
  return null;
}

String _sanitizeName(String v) => v.trim().replaceAll(RegExp(r'\s+'), ' ');

// ─────────────────────────────────────────────────────────────────────────────
//  DATE FORMATTER
// ─────────────────────────────────────────────────────────────────────────────
String _fmtDate(String? iso) {
  if (iso == null) return '—';
  try {
    final d = DateTime.parse(iso).toLocal();
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  } catch (_) { return iso; }
}

// ─────────────────────────────────────────────────────────────────────────────
//  CROSS-PLATFORM IMAGE PICKER
// ─────────────────────────────────────────────────────────────────────────────
Future<({Uint8List bytes, String mime, String ext})?> _pickImage() async {
  final picker = ImagePicker();
  final XFile? picked = await picker.pickImage(
    source: ImageSource.gallery,
    imageQuality: 85,
  );
  if (picked == null) return null;

  final bytes = await picked.readAsBytes();

  if (bytes.lengthInBytes > 2 * 1024 * 1024) {
    throw 'size';
  }

  final ext = picked.name.split('.').last.toLowerCase();
  final mime = ext == 'png'  ? 'image/png'
             : ext == 'webp' ? 'image/webp'
             : 'image/jpeg';

  return (bytes: bytes, mime: mime, ext: ext);
}

// ─────────────────────────────────────────────────────────────────────────────
//  PROFILE SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  final VoidCallback onSignOut;
  const ProfileScreen({super.key, required this.onSignOut});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // ── Data ──────────────────────────────────────────────────────────────────
  Map<String, dynamic>?      _profileData;
  List<BadgeModel>           _earnedBadges    = [];
  List<Map<String, dynamic>> _certificates    = [];
  List<Map<String, dynamic>> _rawBadges       = [];
  int  _completedModules = 0;
  bool _loading          = true;
  bool _editOpen         = false;
  bool _saving           = false;
  bool _uploadingAvatar  = false;
  String? _avatarUrl;
  int     _avatarCacheBust = 0;

  // ── Edit controllers ───────────────────────────────────────────────────────
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl  = TextEditingController();
  final _studentIdCtrl = TextEditingController();

  // ── Field errors ───────────────────────────────────────────────────────────
  String? _firstNameError;
  String? _lastNameError;
  String? _studentIdError;
  String? _deptError;
  String? _courseError;

  // ── Role / academic state ──────────────────────────────────────────────────
  String? _selectedRole;
  String? _selectedDept;
  String? _selectedCourse;
  String  _selectedYear = '1st Year';

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _studentIdCtrl.dispose();
    super.dispose();
  }

  // ── Derived helpers ────────────────────────────────────────────────────────
  String get _displayName =>
      (_profileData?['full_name'] as String? ?? '').trim();

  String get _initials {
    if (_displayName.isEmpty) return '•';
    final parts = _displayName.split(' ')
        .where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return _displayName[0].toUpperCase();
  }

  String get _roleLabel {
    final r = _profileData?['role'] as String? ?? '';
    return r.isEmpty ? '' : r[0].toUpperCase() + r.substring(1);
  }

  String get _joinedDate =>
      _fmtDate(_profileData?['created_at'] as String?);

  bool get _isStudent        => _selectedRole == 'student';
  bool get _isTeacherFaculty =>
      _selectedRole == 'teacher' || _selectedRole == 'faculty';
  bool get _requiresDept     => _isStudent || _isTeacherFaculty;

  bool get _isDirty {
    final fullName   = _profileData?['full_name'] as String? ?? '';
    final parts      = fullName.trim().split(' ')
        .where((p) => p.isNotEmpty).toList();
    final savedFirst = parts.isNotEmpty ? parts.first : '';
    final savedLast  = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    return _firstNameCtrl.text.trim() != savedFirst ||
        _lastNameCtrl.text.trim()  != savedLast  ||
        _studentIdCtrl.text.trim() !=
            (_profileData?['student_id'] as String? ?? '') ||
        _selectedDept   != (_profileData?['department'] as String?) ||
        _selectedCourse != (_profileData?['course']     as String?);
  }

  // ── New-view helpers (real data, not placeholders) ─────────────────────────

  /// Course · Year for students; department for teacher/faculty; '' otherwise.
  String get _metaSecondaryLabel {
    final role = _profileData?['role'] as String? ?? '';
    if (role == 'student') {
      final course = _profileData?['course'] as String?;
      if (course != null && course.isNotEmpty) {
        final rawYear = _profileData?['year_level'];
        final yearLabel = rawYear is int && rawYear >= 1 && rawYear <= 5
            ? kYearLevels[rawYear - 1]
            : (rawYear is String && kYearLevels.contains(rawYear)
                ? rawYear
                : null);
        return yearLabel != null ? '$course · $yearLabel' : course;
      }
    }
    return _profileData?['department'] as String? ?? '';
  }

  /// 0..100, based on which required fields are actually filled in.
  int get _profileCompletionPct {
    final role = _profileData?['role'] as String? ?? '';
    final checks = <bool>[
      _displayName.isNotEmpty,
      (_avatarUrl ?? '').isNotEmpty,
    ];
    if (role == 'student') {
      checks.addAll([
        (_profileData?['student_id'] as String? ?? '').isNotEmpty,
        (_profileData?['department'] as String? ?? '').isNotEmpty,
        (_profileData?['course']     as String? ?? '').isNotEmpty,
        _profileData?['year_level'] != null,
      ]);
    } else if (role == 'teacher' || role == 'faculty') {
      checks.add((_profileData?['department'] as String? ?? '').isNotEmpty);
    }
    if (checks.isEmpty) return 100;
    final done = checks.where((c) => c).length;
    return ((done / checks.length) * 100).round();
  }

  String get _profileCompletionHint {
    final role = _profileData?['role'] as String? ?? '';
    final missing = <String>[];
    if (_displayName.isEmpty) missing.add('your name');
    if ((_avatarUrl ?? '').isEmpty) missing.add('a profile photo');
    if (role == 'student') {
      if ((_profileData?['student_id'] as String? ?? '').isEmpty) {
        missing.add('your student ID');
      }
      if ((_profileData?['department'] as String? ?? '').isEmpty) {
        missing.add('your department');
      }
      if ((_profileData?['course'] as String? ?? '').isEmpty) {
        missing.add('your course');
      }
    } else if (role == 'teacher' || role == 'faculty') {
      if ((_profileData?['department'] as String? ?? '').isEmpty) {
        missing.add('your department');
      }
    }
    if (missing.isEmpty) return 'All set!';
    if (missing.length == 1) return 'Add ${missing.first} to finish';
    return 'Add ${missing.sublist(0, missing.length - 1).join(', ')} '
        'and ${missing.last} to finish';
  }

  List<Widget> get _certPreviews => List.generate(_certificates.length, (i) {
        final cert    = _certificates[i];
        final refType = cert['reference_type'] as String? ?? 'manual';
        final title = refType == 'manual'
            ? 'Certificate of\nAchievement'
            : 'Certificate of\n${refType[0].toUpperCase()}${refType.substring(1)}';
        return ProfileCertPreview(
          title: title,
          date: _fmtDate(cert['issued_at'] as String?),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  CertificateViewerScreen(cert: cert, fullName: _displayName),
            ),
          ),
        );
      });

  List<Widget> get _badgePreviews => List.generate(_rawBadges.length, (i) {
        final raw   = _rawBadges[i];
        final badge = raw['badges'] as Map<String, dynamic>? ?? {};
        return ProfileBadgePreview(
          name: badge['name'] as String? ?? 'Badge',
          iconUrl: badge['icon_url'] as String?,
          date: _fmtDate(raw['awarded_at'] as String?),
          onTap: () => _openBadgeDetail(raw),
        );
      });

  // ── Load ───────────────────────────────────────────────────────────────────
  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      final results = await Future.wait([
        _supabase.from('profiles').select('*').eq('id', userId).maybeSingle(),
        _supabase.from('student_badges')
            .select('*, badges(id, name, description, icon_url, badge_type)')
            .eq('user_id', userId)
            .order('awarded_at', ascending: false),
        _supabase.from('certificates')
            .select('id, user_id, certificate_code, reference_type, '
                'issued_at, is_revoked, body_text, sig1_name, sig1_title, '
                'sig2_name, sig2_title, theme_color')
            .eq('user_id', userId)
            .eq('is_revoked', false)
            .order('issued_at', ascending: false),
        _supabase.from('module_progress')
            .select('status')
            .eq('user_id', userId)
            .eq('status', 'completed'),
      ]);

      final profile   = results[0] as Map<String, dynamic>?;
      // Self-heal: if full_name is null, copy from auth metadata
        if (profile != null && 
            (profile['full_name'] == null || 
            (profile['full_name'] as String).trim().isEmpty)) {
          final meta = _supabase.auth.currentUser?.userMetadata;
          final metaName = meta?['full_name'] as String?;
          if (metaName != null && metaName.isNotEmpty) {
            await _supabase.from('profiles')
                .update({'full_name': metaName})
                .eq('id', userId);
            profile['full_name'] = metaName;
          }
        }

      final rawBadges = List<Map<String, dynamic>>.from(results[1] as List);
      final certs     = List<Map<String, dynamic>>.from(results[2] as List);
      final progress  = results[3] as List;

      final earnedBadges = rawBadges.map((b) {
        final badge = b['badges'] as Map<String, dynamic>? ?? {};
        return BadgeModel.fromMap(badge, earned: true);
      }).toList();

      final fullName  = profile?['full_name'] as String? ?? '';
      final parts     = fullName.trim().split(' ')
          .where((p) => p.isNotEmpty).toList();
      final firstName = parts.isNotEmpty ? parts.first : '';
      final lastName  = parts.length > 1 ? parts.sublist(1).join(' ') : '';

      final savedDept   = profile?['department'] as String?;
      final savedCourse = profile?['course']     as String?;
      final rawYear     = profile?['year_level'];
      final savedYear   = rawYear is int
          ? kYearLevels[(rawYear).clamp(1, 5) - 1]
          : (rawYear as String? ?? '1st Year');

      if (mounted) {
        setState(() {
          _profileData      = profile;
          _earnedBadges     = earnedBadges;
          _rawBadges        = rawBadges;
          _certificates     = certs;
          _completedModules = progress.length;
          _avatarUrl        = profile?['avatar_url'] as String?;

          _firstNameCtrl.text = firstName;
          _lastNameCtrl.text  = lastName;
          _studentIdCtrl.text = profile?['student_id'] as String? ?? '';

          _selectedRole = profile?['role'] as String?;
          _selectedDept = (savedDept != null &&
              kCvsuDeptCourses.containsKey(savedDept)) ? savedDept : null;
          _selectedCourse = (_selectedDept != null &&
              savedCourse != null &&
              kCvsuDeptCourses[_selectedDept]!.contains(savedCourse))
              ? savedCourse : null;
          _selectedYear = kYearLevels.contains(savedYear)
              ? savedYear : '1st Year';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Avatar upload ──────────────────────────────────────────────────────────
  Future<void> _pickAndUploadAvatar() async {
    if (_uploadingAvatar) return;

    Uint8List? bytes;
    String mime = 'image/jpeg';
    String ext  = 'jpg';

    try {
      final result = await _pickImage();
      if (result == null) return;
      bytes = result.bytes;
      mime  = result.mime;
      ext   = result.ext;
    } catch (e) {
      if (e == 'size' && mounted) {
        _showError('Image must be smaller than 2 MB.');
      }
      return;
    }

    setState(() => _uploadingAvatar = true);
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;
      final storagePath = 'avatars/$userId.$ext';
      await _supabase.storage.from('avatars').uploadBinary(
        storagePath, bytes,
        fileOptions: FileOptions(contentType: mime, upsert: true),
      );
      final publicUrl = _supabase.storage
          .from('avatars').getPublicUrl(storagePath);
      await _supabase.from('profiles').update({
        'avatar_url': publicUrl,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);
      if (mounted) {
        setState(() {
          _avatarUrl       = publicUrl;
          _avatarCacheBust = DateTime.now().millisecondsSinceEpoch;
        });
        _showSuccess('Profile picture updated.');
      }
    } catch (_) {
      if (mounted) _showError('Upload failed. Please try again.');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  // ── Validate all fields ────────────────────────────────────────────────────
  bool _validateAll() {
    final fnErr  = _validateName(_firstNameCtrl.text, 'First name');
    final lnErr  = _validateName(_lastNameCtrl.text,  'Last name');

    String? sidErr;
    String? deptErr;
    String? courseErr;

    if (_isStudent) {
      sidErr    = _validateStudentId(_studentIdCtrl.text);
      deptErr   = _selectedDept   == null ? 'Department is required.' : null;
      courseErr = _selectedCourse == null ? 'Course is required.'     : null;
    } else if (_isTeacherFaculty) {
      deptErr   = _selectedDept   == null ? 'Department is required.' : null;
    }

    setState(() {
      _firstNameError = fnErr;
      _lastNameError  = lnErr;
      _studentIdError = sidErr;
      _deptError      = deptErr;
      _courseError    = courseErr;
    });

    return fnErr     == null &&
           lnErr     == null &&
           sidErr    == null &&
           deptErr   == null &&
           courseErr == null;
  }

  // ── Handle back from edit screen ───────────────────────────────────────────
  Future<void> _handleEditBack() async {
    if (_isStudent) {
      final fnErr     = _validateName(_firstNameCtrl.text, 'First name');
      final lnErr     = _validateName(_lastNameCtrl.text,  'Last name');
      final sidErr    = _validateStudentId(_studentIdCtrl.text);
      final deptErr   = _selectedDept   == null ? 'Department is required.' : null;
      final courseErr = _selectedCourse == null ? 'Course is required.'     : null;
      final hasErrors = fnErr != null || lnErr != null || sidErr != null ||
                        deptErr != null || courseErr != null;
      if (hasErrors) {
        setState(() {
          _firstNameError = fnErr;
          _lastNameError  = lnErr;
          _studentIdError = sidErr;
          _deptError      = deptErr;
          _courseError    = courseErr;
        });
        _showError('Please complete all required fields before leaving.');
        return;
      }
    }

    if (_isTeacherFaculty) {
      final fnErr   = _validateName(_firstNameCtrl.text, 'First name');
      final lnErr   = _validateName(_lastNameCtrl.text,  'Last name');
      final deptErr = _selectedDept == null ? 'Department is required.' : null;
      final hasErrors = fnErr != null || lnErr != null || deptErr != null;
      if (hasErrors) {
        setState(() {
          _firstNameError = fnErr;
          _lastNameError  = lnErr;
          _deptError      = deptErr;
        });
        _showError('Please complete all required fields before leaving.');
        return;
      }
    }

    if (!_isDirty) {
      setState(() => _editOpen = false);
      return;
    }

    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text('Unsaved Changes',
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
        content: Text(
          'You have unsaved changes. What would you like to do?',
          style: GoogleFonts.poppins(
              fontSize: 13, color: AppColors.textMid, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: Text('Keep Editing',
                style: GoogleFonts.poppins(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: Text('Discard Changes',
                style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontWeight: FontWeight.w600))),
        ],
      ),
    );

    if (action == 'discard' && mounted) {
      await _load();
      setState(() => _editOpen = false);
    }
  }

  // ── Save profile ───────────────────────────────────────────────────────────
  Future<void> _saveProfile() async {
    if (!_validateAll()) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text('Save Changes?',
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
        content: Text(
          'Are you sure you want to save your profile changes?',
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textMid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.poppins(color: AppColors.textMid))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryDark,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: Text('Save',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      final firstName = _sanitizeName(_firstNameCtrl.text);
      final lastName  = _sanitizeName(_lastNameCtrl.text);
      final fullName  = '$firstName $lastName';
      final rawIndex  = kYearLevels.indexOf(_selectedYear);
      final yearIndex = rawIndex >= 0 ? rawIndex + 1 : null;

      // NOTE: 'role' is intentionally NOT included in this payload.
      // Role is assigned by GADRC (via the CvSU masterlist at signup)
      // and is no longer user-editable from this screen.
      final Map<String, dynamic> payload = {
        'full_name':  fullName,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      if (_isStudent) {
        payload['student_id'] = _studentIdCtrl.text.trim();
        payload['department'] = _selectedDept;
        payload['course']     = _selectedCourse;
        payload['year_level'] = yearIndex;
      } else if (_isTeacherFaculty) {
        payload['student_id'] = null;
        payload['department'] = _selectedDept;
        payload['course']     = null;
        payload['year_level'] = null;
      } else {
        payload['student_id'] = null;
        payload['department'] = null;
        payload['course']     = null;
        payload['year_level'] = null;
      }

      await _supabase.from('profiles').update(payload).eq('id', userId);

      await _load();
      if (mounted) {
        setState(() => _editOpen = false);
        _showSuccess('Profile updated successfully.');
      }
    } catch (_) {
      if (mounted) _showError('Failed to save changes. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Sign out ───────────────────────────────────────────────────────────────
  Future<void> _handleSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text('Sign Out',
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
        content: Text(
          'Are you sure you want to sign out of BLOOM GADRC?',
          style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textMid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel',
                style: GoogleFonts.poppins(color: AppColors.textMid))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.danger,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: Text('Sign Out',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _supabase.auth.signOut();
    } catch (_) {
      await _supabase.auth.signOut(scope: SignOutScope.local);
    } finally {
      widget.onSignOut();
    }
  }

  // ── Snackbars / dialogs ─────────────────────────────────────────────────────
  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins()),
      backgroundColor: AppColors.danger,
    ));
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: GoogleFonts.poppins()),
      backgroundColor: AppColors.primary,
    ));
  }

  void _showComingSoon(String feature) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$feature is coming soon.', style: GoogleFonts.poppins()),
    ));
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('About BLOOM',
            style: GoogleFonts.poppins(
                fontWeight: FontWeight.w700, color: AppColors.textDark)),
        content: Text(
          'BLOOM is the Gender and Development e-learning platform of the '
          'GAD Resource Center, Cavite State University.',
          style: GoogleFonts.poppins(
              fontSize: 13, color: AppColors.textMid, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Close',
                style: GoogleFonts.poppins(
                    color: AppColors.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── Badge detail sheet ─────────────────────────────────────────────────────
  void _openBadgeDetail(Map<String, dynamic> rawBadge) {
    final badge   = rawBadge['badges'] as Map<String, dynamic>? ?? {};
    final name    = badge['name']        as String? ?? 'Badge';
    final desc    = badge['description'] as String? ?? '';
    final icon    = badge['icon_url']    as String?;
    final awarded = _fmtDate(rawBadge['awarded_at'] as String?);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 20),
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4D6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE9C46A), width: 2),
            ),
            child: Center(child: icon != null
                ? ClipRRect(borderRadius: BorderRadius.circular(14),
                    child: Image.network(icon, width: 50, height: 50,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.emoji_events_rounded,
                            size: 40, color: Color(0xFFF59E0B))))
                : const Icon(Icons.emoji_events_rounded,
                    size: 40, color: Color(0xFFF59E0B))),
          ),
          const SizedBox(height: 14),
          Text(name, style: GoogleFonts.poppins(
              fontSize: 20, fontWeight: FontWeight.w700,
              color: const Color(0xFF1A2E1A))),
          const SizedBox(height: 6),
          if (desc.isNotEmpty)
            Text(desc,
                style: GoogleFonts.poppins(
                    fontSize: 13, color: Colors.grey[600]),
                textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(10)),
            child: Text('Awarded on $awarded',
                style: GoogleFonts.poppins(fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF2D6A2D))),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  // ── Avatar widgets ─────────────────────────────────────────────────────────
  Widget _buildAvatarView(double size) {
    final url = _avatarUrl;
    Widget inner = (url != null && url.isNotEmpty)
        ? Image.network('$url?v=$_avatarCacheBust',
            width: size, height: size, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _initialsCircle(size, forHeader: true))
        : _initialsCircle(size, forHeader: true);
    return ClipOval(
        child: SizedBox(width: size, height: size, child: inner));
  }

  Widget _buildAvatarEdit() {
    final url = _avatarUrl;
    Widget inner = (url != null && url.isNotEmpty)
        ? Image.network('$url?v=$_avatarCacheBust',
            width: 100, height: 100, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _initialsCircle(100, forHeader: false))
        : _initialsCircle(100, forHeader: false);

    return Stack(children: [
      Container(
        width: 100, height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.primaryDark, width: 3),
        ),
        child: ClipOval(child: inner),
      ),
      Positioned(
        bottom: 0, right: 0,
        child: GestureDetector(
          onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
          child: Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: AppColors.primaryDark,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: _uploadingAvatar
                ? const Padding(padding: EdgeInsets.all(7),
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.camera_alt_outlined,
                    color: Colors.white, size: 16),
          ),
        ),
      ),
    ]);
  }

  Widget _initialsCircle(double size, {required bool forHeader}) =>
      Container(
        width: size, height: size,
        color: forHeader
            ? Colors.white.withValues(alpha: 0.2)
            : AppColors.primaryDark.withValues(alpha: 0.12),
        child: Center(child: Text(_initials,
            style: TextStyle(
                fontSize: size * 0.33,
                color: forHeader ? Colors.white : AppColors.primaryDark,
                fontWeight: FontWeight.w900))),
      );

  // ── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_editOpen) return _buildEditProfile();
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Container(
          color: AppColors.background,
          child: Column(children: [
            _header(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: _loading
                  ? const Center(child: Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(
                          color: AppColors.primary)))
                  : Column(children: [
                      _statsStrip(),
                      if (_profileCompletionPct < 100) ...[
                        const SizedBox(height: 16),
                        _completionNudge(),
                      ],
                      const SizedBox(height: 16),
                      _railSection(
                        icon: Icons.workspace_premium_outlined,
                        title: 'My Certificates',
                        count: _certificates.length,
                        accent: AppColors.primary,
                        children: _certPreviews,
                        emptyText:
                            'Complete modules & seminars to earn certificates',
                      ),
                      const SizedBox(height: 16),
                      _railSection(
                        icon: Icons.emoji_events_rounded,
                        title: 'My Badges',
                        count: _earnedBadges.length,
                        accent: AppColors.accent,
                        children: _badgePreviews,
                        emptyText: 'Complete assessments to earn badges',
                      ),
                      const SizedBox(height: 18),
                      _menuGroup('Account', [
                        _MenuItem(Icons.person_outline_rounded, 'Edit profile',
                            'Name, course, year level',
                            () => setState(() => _editOpen = true)),
                      ]),
                      const SizedBox(height: 18),
                      _menuGroup('Support', [
                        _MenuItem(Icons.help_outline_rounded, 'Help & support',
                            'FAQ and contact GADRC',
                            () => Navigator.push(context, MaterialPageRoute(
                                builder: (_) => const HelpScreen()))),
                        _MenuItem(Icons.info_outline_rounded, 'About BLOOM',
                            'GADRC · Cavite State University',
                            _showAboutDialog),
                      ]),
                      const SizedBox(height: 18),
                      _signOutButton(),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────────────
  Widget _header() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
          child: Column(
            children: [
              Stack(
                children: [
                  Container(
                    width: 92,
                    height: 92,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.45), width: 3),
                    ),
                    child: _buildAvatarView(92),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _uploadingAvatar ? null : _pickAndUploadAvatar,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AppColors.primaryDark, width: 2),
                        ),
                        child: _uploadingAvatar
                            ? const Padding(
                                padding: EdgeInsets.all(7),
                                child: CircularProgressIndicator(
                                    color: AppColors.primaryDark, strokeWidth: 2))
                            : const Icon(Icons.photo_camera_outlined,
                                color: AppColors.primaryDark, size: 15),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(_displayName.isEmpty ? 'Your name' : _displayName,
                  style: GoogleFonts.nunito(
                      color: Colors.white, fontSize: 21, fontWeight: FontWeight.w900)),
              if (_roleLabel.isNotEmpty) ...[
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(_roleLabel.toUpperCase(),
                      style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5)),
                ),
              ],
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) => ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (_metaSecondaryLabel.isNotEmpty)
                        _metaChip(Icons.school_outlined, _metaSecondaryLabel,
                            maxWidth: constraints.maxWidth - 32),
                      _metaChip(
                          Icons.calendar_today_outlined, 'Joined $_joinedDate'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String label, {double? maxWidth}) => Container(
        constraints: maxWidth != null ? BoxConstraints(maxWidth: maxWidth) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 13),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: GoogleFonts.nunito(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  // ── Stats strip ──────────────────────────────────────────────────────────
  Widget _statsStrip() {
    Widget item(IconData icon, String value, String label, Color color) =>
        Expanded(
          child: Column(
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(value,
                  style: GoogleFonts.nunito(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textDark)),
              Text(label,
                  style: GoogleFonts.nunito(
                      fontSize: 11, color: AppColors.textLight)),
            ],
          ),
        );
    Widget divider() => Container(width: 1, height: 40, color: AppColors.border);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.07),
              blurRadius: 12,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          item(Icons.emoji_events_rounded, '${_earnedBadges.length}', 'Badges',
              AppColors.accent),
          divider(),
          item(Icons.workspace_premium_outlined, '${_certificates.length}',
              'Certificates', AppColors.primary),
          divider(),
          item(Icons.check_circle_outline_rounded, '$_completedModules',
              'Modules', AppColors.info),
        ],
      ),
    );
  }

  // ── Completion nudge ─────────────────────────────────────────────────────
  Widget _completionNudge() {
    return GestureDetector(
      onTap: () => setState(() => _editOpen = true),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.badge_outlined,
                  color: AppColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Complete your profile',
                      style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textDark)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: _profileCompletionPct / 100,
                      minHeight: 6,
                      backgroundColor: AppColors.border,
                      valueColor:
                          const AlwaysStoppedAnimation(AppColors.primary),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('$_profileCompletionPct% · $_profileCompletionHint',
                      style: GoogleFonts.nunito(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textLight)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.primary, size: 20),
          ],
        ),
      ),
    );
  }

  // ── Rail section ─────────────────────────────────────────────────────────
  Widget _railSection({
    required IconData icon,
    required String title,
    required int count,
    required Color accent,
    required List<Widget> children,
    required String emptyText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Icon(icon, size: 16, color: AppColors.textDark),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: GoogleFonts.nunito(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textDark)),
              ),
              if (count > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('$count',
                      style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: accent)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (children.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                Icon(icon, size: 30, color: AppColors.textLight),
                const SizedBox(height: 8),
                Text(emptyText,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.nunito(
                        fontSize: 12, color: AppColors.textLight)),
              ],
            ),
          )
        else
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: children.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) => children[i],
            ),
          ),
      ],
    );
  }

  // ── Menu group ───────────────────────────────────────────────────────────
  Widget _menuGroup(String title, List<_MenuItem> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title.toUpperCase(),
              style: GoogleFonts.nunito(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: AppColors.textLight)),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.07),
                  blurRadius: 12,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: Column(
            children: [
              for (int i = 0; i < items.length; i++) ...[
                InkWell(
                  onTap: items[i].onTap,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 13, horizontal: 16),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.09),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(items[i].icon,
                              size: 20, color: AppColors.primary),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(items[i].label,
                                  style: GoogleFonts.nunito(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textDark)),
                              const SizedBox(height: 2),
                              Text(items[i].sub,
                                  style: GoogleFonts.nunito(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textLight)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded,
                            size: 20, color: AppColors.textLight),
                      ],
                    ),
                  ),
                ),
                if (i < items.length - 1)
                  Divider(height: 1, color: AppColors.background, indent: 16, endIndent: 16),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _signOutButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _handleSignOut,
        icon: const Icon(Icons.logout_rounded, size: 18, color: AppColors.danger),
        label: Text('Sign out',
            style: GoogleFonts.nunito(
                color: AppColors.danger,
                fontWeight: FontWeight.w800,
                fontSize: 14)),
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.danger.withValues(alpha: 0.06),
          side: BorderSide(
              color: AppColors.danger.withValues(alpha: 0.35), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: const EdgeInsets.symmetric(vertical: 15),
        ),
      ),
    );
  }

  // ── EDIT PROFILE ───────────────────────────────────────────────────────────
  Widget _buildEditProfile() {
    final deptCourseList = _selectedDept != null
        ? kCvsuDeptCourses[_selectedDept] ?? <String>[]
        : <String>[];

    final bool showDept       = _requiresDept;
    final bool showCourseYear = _isStudent;
    final bool showStudentId  = _isStudent;

    return PopScope(
      canPop: false,
      onPopInvoked: (_) => _handleEditBack(),
      child: Column(children: [

        // ── Top bar ────────────────────────────────────────────────────
        Container(
          color: Colors.white,
          padding: EdgeInsets.fromLTRB(
              8, MediaQuery.of(context).padding.top + 8, 16, 12),
          child: Row(children: [
            IconButton(
              onPressed: _handleEditBack,
              icon: const Icon(Icons.chevron_left_rounded,
                  color: AppColors.textMid, size: 28)),
            Text('Edit Profile',
                style: GoogleFonts.poppins(
                    fontSize: 18, fontWeight: FontWeight.w700,
                    color: AppColors.textDark)),
          ]),
        ),
        const Divider(height: 1, color: AppColors.border),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [

              // ── Avatar ──────────────────────────────────────────────
              Center(child: Column(children: [
                _buildAvatarEdit(),
                const SizedBox(height: 8),
                Text('Tap camera to change photo',
                    style: GoogleFonts.poppins(
                        fontSize: 12, color: AppColors.textLight)),
              ])),
              const SizedBox(height: 20),

              // ── Personal information ────────────────────────────────
              AppCard(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('Personal Information'),
                  const SizedBox(height: 14),
                  Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Expanded(child: _ValidatedField(
                      label: 'First Name *',
                      controller: _firstNameCtrl,
                      icon: Icons.person_outline_rounded,
                      error: _firstNameError,
                      onChanged: (_) => setState(() =>
                          _firstNameError = _validateName(
                              _firstNameCtrl.text, 'First name')),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: _ValidatedField(
                      label: 'Last Name *',
                      controller: _lastNameCtrl,
                      icon: Icons.person_outline_rounded,
                      error: _lastNameError,
                      onChanged: (_) => setState(() =>
                          _lastNameError = _validateName(
                              _lastNameCtrl.text, 'Last name')),
                    )),
                  ]),

                  if (showStudentId) ...[
                    const SizedBox(height: 12),
                    _ValidatedField(
                      label: 'Student ID *',
                      controller: _studentIdCtrl,
                      icon: Icons.badge_outlined,
                      error: _studentIdError,
                      keyboardType: TextInputType.text,
                      onChanged: (_) => setState(() =>
                          _studentIdError =
                              _validateStudentId(_studentIdCtrl.text)),
                    ),
                  ],
                ],
              )),
              const SizedBox(height: 12),

              // ── Role (read-only) ───────────────────────────────────
              AppCard(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('Role'),
                  const SizedBox(height: 4),
                  Text(
                    'Your role is assigned by GADRC and cannot be changed here.',
                    style: GoogleFonts.poppins(
                        fontSize: 11, color: AppColors.textLight),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(children: [
                      const Icon(Icons.verified_user_outlined,
                          color: AppColors.textMid, size: 18),
                      const SizedBox(width: 10),
                      Text(
                        _selectedRole == null || _selectedRole!.isEmpty
                            ? 'Not set'
                            : _selectedRole![0].toUpperCase() +
                                _selectedRole!.substring(1),
                        style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.textDark),
                      ),
                    ]),
                  ),
                  if (_isStudent) ...[
                    const SizedBox(height: 10),
                    _RequiredFieldsHint(
                        text: 'Student role requires: Student ID, '
                            'Department, Course & Year Level'),
                  ] else if (_isTeacherFaculty) ...[
                    const SizedBox(height: 10),
                    _RequiredFieldsHint(
                        text: 'Teacher/Faculty role requires: Department'),
                  ],
                ],
              )),
              const SizedBox(height: 12),

              // ── Academic details ────────────────────────────────────
              if (showDept) ...[
                AppCard(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel('Academic Details'),
                    const SizedBox(height: 14),

                    _DropdownField<String>(
                      label: 'Department / College *',
                      icon: Icons.account_balance_outlined,
                      value: _selectedDept,
                      items: kCvsuDeptCourses.keys.toList(),
                      itemLabel: (d) => d,
                      error: _deptError,
                      onChanged: (d) => setState(() {
                        _selectedDept   = d;
                        _selectedCourse = null;
                        _deptError      = null;
                      }),
                    ),

                    if (showCourseYear) ...[
                      const SizedBox(height: 12),
                      _DropdownField<String>(
                        label: 'Course / Program *',
                        icon: Icons.school_outlined,
                        value: _selectedCourse,
                        items: deptCourseList,
                        itemLabel: (c) => c,
                        error: _courseError,
                        onChanged: _selectedDept == null
                            ? null
                            : (c) => setState(() {
                                  _selectedCourse = c;
                                  _courseError    = null;
                                }),
                        hint: _selectedDept == null
                            ? 'Select department first'
                            : 'Select course',
                      ),
                      const SizedBox(height: 12),
                      _DropdownField<String>(
                        label: 'Year Level *',
                        icon: Icons.calendar_today_outlined,
                        value: _selectedYear,
                        items: kYearLevels,
                        itemLabel: (y) => y,
                        onChanged: (y) => setState(
                            () => _selectedYear = y ?? '1st Year'),
                      ),
                    ],
                  ],
                )),
                const SizedBox(height: 12),
              ],

              // ── Save button ─────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _saveProfile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryDark,
                    disabledBackgroundColor:
                        AppColors.primaryDark.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 0,
                  ),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : Text('Save Changes',
                          style: GoogleFonts.poppins(
                              fontSize: 15, fontWeight: FontWeight.w600,
                              color: Colors.white)),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _sectionLabel(String text) => Text(text,
      style: GoogleFonts.poppins(
          fontSize: 12, fontWeight: FontWeight.w600,
          color: AppColors.textMid, letterSpacing: 0.5));
}

class _MenuItem {
  final IconData icon;
  final String label, sub;
  final VoidCallback onTap;
  const _MenuItem(this.icon, this.label, this.sub, this.onTap);
}

// ─────────────────────────────────────────────────────────────────────────────
//  REQUIRED FIELDS HINT
// ─────────────────────────────────────────────────────────────────────────────
class _RequiredFieldsHint extends StatelessWidget {
  final String text;
  const _RequiredFieldsHint({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppColors.primary.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.info_outline_rounded,
          color: AppColors.primary, size: 15),
      const SizedBox(width: 8),
      Expanded(child: Text(text,
          style: GoogleFonts.poppins(
              fontSize: 11, color: AppColors.primary, height: 1.4))),
    ]),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  VALIDATED TEXT FIELD
// ─────────────────────────────────────────────────────────────────────────────
class _ValidatedField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final IconData icon;
  final String? error;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;

  const _ValidatedField({
    required this.label,
    required this.controller,
    required this.icon,
    this.error,
    this.onChanged,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: GoogleFonts.poppins(
              fontSize: 12, fontWeight: FontWeight.w500,
              color: AppColors.textDark)),
      const SizedBox(height: 6),
      TextField(
        controller:   controller,
        onChanged:    onChanged,
        keyboardType: keyboardType,
        style: GoogleFonts.poppins(
            fontSize: 14, color: AppColors.textDark),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: AppColors.textLight, size: 18),
          filled:     true,
          fillColor:  AppColors.background,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          errorText:     error,
          errorStyle:    GoogleFonts.poppins(fontSize: 11),
          errorMaxLines: 2,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                  color: error != null
                      ? AppColors.danger
                      : AppColors.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                  color: AppColors.primaryDark, width: 1.5)),
          focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                  color: AppColors.danger, width: 1.5)),
        ),
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  DROPDOWN FIELD
// ─────────────────────────────────────────────────────────────────────────────
class _DropdownField<T> extends StatelessWidget {
  final String label;
  final IconData icon;
  final T? value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T?>? onChanged;
  final String? hint;
  final String? error;

  const _DropdownField({
    required this.label,
    required this.icon,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
    this.hint,
    this.error,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: GoogleFonts.poppins(
              fontSize: 12, fontWeight: FontWeight.w500,
              color: AppColors.textDark)),
      const SizedBox(height: 6),
      DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        hint: Text(hint ?? 'Select',
            style: GoogleFonts.poppins(
                fontSize: 13, color: AppColors.textLight)),
        style: GoogleFonts.poppins(
            fontSize: 13, color: AppColors.textDark),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, color: AppColors.textLight, size: 18),
          filled:    true,
          fillColor: onChanged == null
              ? AppColors.border.withValues(alpha: 0.3)
              : AppColors.background,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          errorText:    error,
          errorStyle:   GoogleFonts.poppins(fontSize: 11),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                  color: error != null
                      ? AppColors.danger
                      : AppColors.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                  color: AppColors.primaryDark, width: 1.5)),
          disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border)),
          focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                  color: AppColors.danger, width: 1.5)),
        ),
        items: items.map((item) => DropdownMenuItem<T>(
          value: item,
          child: Text(itemLabel(item),
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.poppins(fontSize: 13)),
        )).toList(),
        onChanged: onChanged,
      ),
    ],
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  Preview cards for the certificate / badge rails
// ─────────────────────────────────────────────────────────────────────────────
class ProfileCertPreview extends StatelessWidget {
  final String title; // already includes "\n" if you want 2 lines
  final String date;
  final VoidCallback onTap;
  const ProfileCertPreview(
      {super.key, required this.title, required this.date, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFC8E6C9), width: 1.5),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 6,
                offset: const Offset(0, 2)),
          ],
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.workspace_premium_rounded,
                  size: 28, color: Color(0xFF2D6A2D)),
            ),
            const SizedBox(height: 6),
            Text(title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryDark)),
            const SizedBox(height: 2),
            Text(date,
                style: GoogleFonts.nunito(fontSize: 9, color: AppColors.textLight)),
          ],
        ),
      ),
    );
  }
}

class ProfileBadgePreview extends StatelessWidget {
  final String name;
  final String? iconUrl;
  final String date;
  final VoidCallback onTap;
  const ProfileBadgePreview(
      {super.key,
      required this.name,
      this.iconUrl,
      required this.date,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE9C46A), width: 1.5),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 6,
                offset: const Offset(0, 2)),
          ],
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFFFF4D6), Color(0xFFF8E1A1)],
                ),
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
              child: Center(
                child: (iconUrl ?? '').isNotEmpty
                    ? Image.network(iconUrl!,
                        width: 30,
                        height: 30,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.military_tech_rounded,
                            size: 26,
                            color: AppColors.primaryDark))
                    : const Icon(Icons.military_tech_rounded,
                        size: 26, color: AppColors.primaryDark),
              ),
            ),
            const SizedBox(height: 6),
            Text(name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.nunito(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryDark)),
            const SizedBox(height: 2),
            Text(date,
                style: GoogleFonts.nunito(fontSize: 9, color: AppColors.textLight)),
          ],
        ),
      ),
    );
  }
}