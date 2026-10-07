// lib/main.dart
// BLOOM GAD Mobile App — Main entry point + AuthGate
//
// Access rule (applies to EVERY sign-in method — email/password, OTP,
// Google on phone, and Google on the web):
//   • The account's email must be in the BLOOM masterlist and active.
//     This covers CvSU students/staff (@cvsu.edu.ph) AND outsiders the
//     GADRC admin added (e.g. Gmail). Anyone else is signed out.
//   • The role always comes from the masterlist (no more "force guest").

import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'theme/app_theme.dart';
import 'services/auth_service.dart';
import 'screens/login_screen.dart';
import 'screens/signup_screen.dart';
import 'screens/otp_screen.dart';
import 'screens/reset_password_screen.dart';
import 'screens/main_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url:     'https://vfpgzuehfebhawlidhsz.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZmcGd6dWVoZmViaGF3bGlkaHN6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzMwMjk4ODMsImV4cCI6MjA4ODYwNTg4M30.ZzaOTYxShnwwLDMNH1uZKb59lYsB6pnNk1mPik2VRR0',
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.implicit,
    ),
  );

  // NOTE: Google Sign-In is initialized inside AuthService.signInWithGoogle()
  // with the real client IDs. It must not be initialized a second time here.

  runApp(const BloomApp());
}

class BloomApp extends StatelessWidget {
  const BloomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:                      'BLOOM GAD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

// ── Auth status ───────────────────────────────────────────────────────────────
enum _AuthStatus {
  loading,
  unauthenticated,
  authenticated,
  passwordRecovery,
  deactivated,
  notInMasterlist,
}

// ── Recovery URL detection (web only) ────────────────────────────────────────
bool _isRecoveryUrl() {
  if (!kIsWeb) return false;
  final fragment = Uri.base.fragment;
  if (fragment.isNotEmpty) {
    final params = Uri.splitQueryString(fragment);
    if (params['type'] == 'recovery') return true;
  }
  return Uri.base.queryParameters['type'] == 'recovery';
}

// ── AuthGate ──────────────────────────────────────────────────────────────────
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  _AuthStatus         _status  = _AuthStatus.loading;
  StreamSubscription? _authSub;
  StreamSubscription? _linkSub;
  RealtimeChannel?    _profileChannel;
  Timer?              _pollTimer;
  int                 _checkId = 0;
  String              _resolvedRole  = '';
  String              _blockedEmail  = '';

  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _initAuth();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _linkSub?.cancel();
    _stopDeactivationWatcher();
    super.dispose();
  }

  // ── Deactivation watcher ──────────────────────────────────────────────────
  void _startDeactivationWatcher(String userId) {
    _stopDeactivationWatcher();
    _profileChannel = _supabase
        .channel('profile-deactivation-$userId')
        .onPostgresChanges(
          event:  PostgresChangeEvent.update,
          schema: 'public',
          table:  'profiles',
          filter: PostgresChangeFilter(
            type:   PostgresChangeFilterType.eq,
            column: 'id',
            value:  userId,
          ),
          callback: (payload) {
            final isActive = payload.newRecord['is_active'];
            if (isActive == false) _handleDeactivated();
          },
        )
        .subscribe();

    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final user = _supabase.auth.currentUser;
      if (user == null) return;
      try {
        final row = await _supabase
            .from('profiles')
            .select('is_active')
            .eq('id', user.id)
            .maybeSingle();
        if (row != null && row['is_active'] == false) _handleDeactivated();
      } catch (_) {}
    });
  }

  void _stopDeactivationWatcher() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_profileChannel != null) {
      _supabase.removeChannel(_profileChannel!);
      _profileChannel = null;
    }
  }

  Future<void> _handleDeactivated() async {
    _stopDeactivationWatcher();
    try { await AuthService.signOut(); } catch (_) {}
    if (mounted) setState(() => _status = _AuthStatus.deactivated);
  }

  // ── Deep links ────────────────────────────────────────────────────────────
  void _initDeepLinks() {
    if (kIsWeb) return;
    final appLinks = AppLinks();
    appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleDeepLink(uri);
    });
    _linkSub = appLinks.uriLinkStream.listen(_handleDeepLink);
  }

  void _handleDeepLink(Uri uri) {
    if (uri.host == 'reset-callback') {
      if (mounted) setState(() => _status = _AuthStatus.passwordRecovery);
    }
  }

  // ── Auth init ─────────────────────────────────────────────────────────────
  Future<void> _initAuth() async {
    if (_isRecoveryUrl()) {
      if (mounted) setState(() => _status = _AuthStatus.passwordRecovery);
      _subscribeToAuthEvents();
      return;
    }
    _subscribeToAuthEvents();
    final session = _supabase.auth.currentSession;
    if (session != null) {
      await _safeResolve();
    } else {
      if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
    }
  }

  // Runs the checks, and if anything unexpected fails, returns to the
  // login screen instead of leaving the app stuck on the loading spinner.
  Future<void> _safeResolve() async {
    try {
      await _resolveAuthenticatedStatus();
    } catch (_) {
      try { await AuthService.signOut(); } catch (_) {}
      if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
    }
  }

  void _subscribeToAuthEvents() {
    _authSub = _supabase.auth.onAuthStateChange.listen(
      (data) async {
        final event = data.event;
        if (event == AuthChangeEvent.tokenRefreshed) return;

        if (event == AuthChangeEvent.passwordRecovery) {
          if (mounted) setState(() => _status = _AuthStatus.passwordRecovery);
          return;
        }

        if (event == AuthChangeEvent.signedIn) {
          if (_isRecoveryUrl()) {
            if (mounted) setState(() => _status = _AuthStatus.passwordRecovery);
            return;
          }
          await _safeResolve();
          return;
        }

        if (event == AuthChangeEvent.signedOut) {
          if (_status == _AuthStatus.authenticated) {
            _stopDeactivationWatcher();
            if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
          }
          return;
        }
      },
      onError: (_) {
        if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
      },
    );
  }

  // ── Resolve status (runs after EVERY sign-in and on app start) ────────────
  //
  //  1. Email must be in the masterlist (and active)  → otherwise signed out
  //  2. Profile must not be deactivated               → otherwise signed out
  //  3. Role comes from the profile, or from the masterlist if missing
  //
  Future<void> _resolveAuthenticatedStatus() async {
    final myCheckId = ++_checkId;
    final user = _supabase.auth.currentUser;

    if (user == null) {
      if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
      return;
    }

    final email = (user.email ?? '').toLowerCase().trim();

    // ── 1. Masterlist gate (CvSU emails AND admin-added outsiders) ─────────
    bool? inMasterlist;
    try {
      final result = await _supabase
          .rpc('is_email_in_masterlist', params: {'lookup_email': email})
          .timeout(const Duration(seconds: 10));
      inMasterlist = result == true;
    } catch (_) {
      inMasterlist = null; // couldn't check (offline / timeout)
    }
    if (!mounted || myCheckId != _checkId) return;

    if (inMasterlist == false) {
      _stopDeactivationWatcher();
      try { await AuthService.signOut(); } catch (_) {}
      if (!mounted) return;
      setState(() {
        _blockedEmail = email;
        _status = _AuthStatus.notInMasterlist;
      });
      return;
    }

    // ── 2. Profile / deactivation check ────────────────────────────────────
    try {
      final profile = await _supabase
          .from('profiles')
          .select('role, is_active')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));

      if (!mounted || myCheckId != _checkId) return;

      if (profile != null && profile['is_active'] == false) {
        _stopDeactivationWatcher();
        await AuthService.signOut();
        if (mounted) setState(() => _status = _AuthStatus.deactivated);
        return;
      }

      var role = (profile?['role'] as String? ?? '').trim();

      // Couldn't reach the masterlist check AND there's no known profile:
      // don't let an unverified account in.
      if (inMasterlist == null && role.isEmpty) {
        await AuthService.signOut();
        if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
        return;
      }

      // ── 3. Role from the masterlist if the profile doesn't have one ─────
      if (role.isEmpty) {
        role = await _recoverRoleFromMasterlist(user.id, email) ?? '';
        if (!mounted || myCheckId != _checkId) return;
      }

      _startDeactivationWatcher(user.id);
      _resolvedRole = role.isNotEmpty ? role : 'student';
      if (mounted) setState(() => _status = _AuthStatus.authenticated);
    } catch (_) {
      if (!mounted || myCheckId != _checkId) return;
      if (inMasterlist == true) {
        _startDeactivationWatcher(user.id);
        if (mounted) setState(() => _status = _AuthStatus.authenticated);
      } else {
        await AuthService.signOut();
        if (mounted) setState(() => _status = _AuthStatus.unauthenticated);
      }
    }
  }

  /// Copies the person's details from the masterlist into their profile.
  /// Works for CvSU emails AND admin-added outsiders. Returns the role.
  Future<String?> _recoverRoleFromMasterlist(String userId, String email) async {
    try {
      final row = await _supabase
          .from('masterlist')
          .select('role, full_name, student_id, department, course, year_level, sex')
          .eq('cvsu_email', email)
          .eq('is_active', true)
          .maybeSingle();

      if (row == null) return null;

      final rawYear = row['year_level'];
      final yearIdx = rawYear is int ? rawYear : null;

      await _supabase.from('profiles').upsert({
        'id':         userId,
        'email':      email,
        'full_name':  row['full_name'],
        'role':       row['role'],
        'student_id': row['student_id'],
        'department': row['department'],
        'course':     row['course'],
        'year_level': yearIdx,
        if (row['sex'] == 'male' || row['sex'] == 'female') 'sex': row['sex'],
        'is_active':  true,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');

      return row['role'] as String?;
    } catch (_) {
      return null;
    }
  }

  // ── Callbacks ─────────────────────────────────────────────────────────────
  void _handleOtpVerified() {}   // auth stream handles navigation

  // Google sign-in finished → run the same masterlist/role checks
  void _handleGuestAuth() => _safeResolve();

  void _handleSignOut() {
    _stopDeactivationWatcher();
    setState(() => _status = _AuthStatus.unauthenticated);
  }
  void _handleResetComplete() => setState(() => _status = _AuthStatus.unauthenticated);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: switch (_status) {

        _AuthStatus.loading =>
          const _SplashScreen(),

        _AuthStatus.unauthenticated =>
          _AuthNavigator(
            key:           const ValueKey('authNav'),
            onGuestAuth:   _handleGuestAuth,
            onOtpVerified: _handleOtpVerified,
          ),

        _AuthStatus.authenticated =>
          MainShell(
            key:          const ValueKey('mainShell'),
            onSignOut:    _handleSignOut,
            resolvedRole: _resolvedRole,
          ),

        _AuthStatus.passwordRecovery =>
          ResetPasswordScreen(
            key:        const ValueKey('resetPassword'),
            onComplete: _handleResetComplete,
          ),

        _AuthStatus.deactivated =>
          _BlockedScreen(
            key:     const ValueKey('deactivated'),
            title:   'Account Deactivated',
            message: 'Your account has been deactivated by an administrator.\n\n'
                     'Please contact your administrator for assistance.',
            onClose: () => setState(() => _status = _AuthStatus.unauthenticated),
          ),

        _AuthStatus.notInMasterlist =>
          _BlockedScreen(
            key:     const ValueKey('notInMasterlist'),
            title:   'Not in the Masterlist',
            message: 'The account $_blockedEmail is not in the BLOOM masterlist.\n\n'
                     'Please contact the GADRC to be added first.',
            onClose: () => setState(() => _status = _AuthStatus.unauthenticated),
          ),
      },
    );
  }
}

// ── Splash ────────────────────────────────────────────────────────────────────
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: AppColors.background,
    body: Center(child: CircularProgressIndicator(color: AppColors.primary)),
  );
}

// ── Blocked (deactivated / not in masterlist) ─────────────────────────────────
class _BlockedScreen extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onClose;
  const _BlockedScreen({
    super.key,
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFEF2F2),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(20)),
                child: const Icon(Icons.shield_outlined,
                    size: 40, color: Color(0xFFDC2626)),
              ),
              const SizedBox(height: 24),
              Text(title,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800,
                      color: Color(0xFF1A2E1A)),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(message,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280), height: 1.6),
                textAlign: TextAlign.center),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: onClose,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                  child: const Text('OK',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Auth navigator ────────────────────────────────────────────────────────────
enum _AuthView { login, signup, signupOtp, loginOtp }

class _AuthNavigator extends StatefulWidget {
  final VoidCallback onGuestAuth;
  final VoidCallback onOtpVerified;

  const _AuthNavigator({
    super.key,
    required this.onGuestAuth,
    required this.onOtpVerified,
  });

  @override
  State<_AuthNavigator> createState() => _AuthNavigatorState();
}

class _AuthNavigatorState extends State<_AuthNavigator> {
  _AuthView _view = _AuthView.login;

  String?  _otpEmail;
  String?  _otpFullName;
  String   _otpRole       = '';
  String?  _otpStudentId;
  String?  _otpDepartment;
  String?  _otpCourse;
  int?     _otpYearLevel;
  String?  _loginOtpEmail;

  void _goToLogin()  => setState(() => _view = _AuthView.login);
  void _goToSignup() => setState(() => _view = _AuthView.signup);

  void _goToSignupOtp({
    required String  email,
    required String  fullName,
    required String  role,
    required String? studentId,
    required String? department,
    required String? course,
    required int?    yearLevel,
  }) {
    setState(() {
      _otpEmail      = email;
      _otpFullName   = fullName;
      _otpRole       = role;
      _otpStudentId  = studentId;
      _otpDepartment = department;
      _otpCourse     = course;
      _otpYearLevel  = yearLevel;
      _view          = _AuthView.signupOtp;
    });
  }

  void _goToLoginOtp({ required String email }) {
    setState(() {
      _loginOtpEmail = email;
      _view          = _AuthView.loginOtp;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: switch (_view) {

        _AuthView.login => LoginScreen(
          key:          const ValueKey('login'),
          onLogin:      (String email) => _goToLoginOtp(email: email),
          onGuestLogin: widget.onGuestAuth,
          onGoSignup:   _goToSignup,
        ),

        _AuthView.signup => SignupScreen(
          key:           const ValueKey('signup'),
          onGoLogin:     _goToLogin,
          onNeedsOtp: ({
            required String  email,
            required String  fullName,
            required String  role,
            required String? studentId,
            required String? department,
            required String? course,
            required int?    yearLevel,
          }) => _goToSignupOtp(
            email:      email,
            fullName:   fullName,
            role:       role,
            studentId:  studentId,
            department: department,
            course:     course,
            yearLevel:  yearLevel,
          ),
          onGuestSignup: widget.onGuestAuth,
        ),

        _AuthView.signupOtp => OtpScreen(
          key:        const ValueKey('signupOtp'),
          email:      _otpEmail!,
          fullName:   _otpFullName!,
          role:       _otpRole,
          studentId:  _otpStudentId,
          department: _otpDepartment,
          course:     _otpCourse,
          yearLevel:  _otpYearLevel,
          onVerified: widget.onOtpVerified,
          onBack:     _goToSignup,
        ),

        _AuthView.loginOtp => OtpScreen(
          key:        const ValueKey('loginOtp'),
          email:      _loginOtpEmail!,
          fullName:   '',
          onVerified: widget.onOtpVerified,
          onBack:     _goToLogin,
        ),
      },
    );
  }
}