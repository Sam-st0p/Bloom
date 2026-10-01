// lib/screens/login_screen.dart
// BLOOM GAD Mobile App — Sign In Screen
//
// Constructor API matches _AuthNavigator in main.dart:
//   onLogin      → called after successful email/password sign-in
//   onGuestLogin → called after Google sign-in succeeds
//   onGoSignup   → navigate to SignupScreen
//
// Access is limited to the BLOOM masterlist:
//   • CvSU students/staff with their @cvsu.edu.ph email
//   • Outsiders added by the GADRC admin (any email, e.g. Gmail)
// Google sign-in is also checked against the masterlist (AuthService).
 
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../services/auth_service.dart';
 
 
class LoginScreen extends StatefulWidget {
  final void Function(String email) onLogin;
  final VoidCallback onGuestLogin;
  final VoidCallback onGoSignup;
 
  const LoginScreen({
    super.key,
    required this.onLogin,
    required this.onGuestLogin,
    required this.onGoSignup,
  });
 
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}
 
 
class _LoginScreenState extends State<LoginScreen> {
  final _formKey     = GlobalKey<FormState>();
  final _emailCtrl   = TextEditingController();
  final _passCtrl    = TextEditingController();
 
  // Owned by this State so it is never disposed while the
  // "forgot password" sheet is still animating off-screen.
  final _resetCtrl = TextEditingController();
 
  bool    _obscurePass = true;
  bool    _loading     = false;
  String? _error;
 
  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _resetCtrl.dispose();
    super.dispose();
  }
 
  // ── Helpers ───────────────────────────────────────────────────────────────
 
  bool get _isValidEmail => AppValidators.email(_emailCtrl.text) == null;
 
  bool get _isCvsuEmail =>
      _emailCtrl.text.trim().toLowerCase().endsWith('@cvsu.edu.ph');
 
  // ── Email / password sign-in ──────────────────────────────────────────────
 
  Future<void> _handleLogin() async {
    if (_loading) return;
    setState(() => _error = null);
 
    if (!(_formKey.currentState?.validate() ?? false)) return;
 
    setState(() => _loading = true);
 
    final error = await AuthService.signIn(
      AppValidators.normalizeEmail(_emailCtrl.text),
      _passCtrl.text,
    );
 
    if (!mounted) return;
 
    if (error != null) {
      setState(() { _error = error; _loading = false; });
      return;
    }
 
    widget.onLogin(AppValidators.normalizeEmail(_emailCtrl.text));
  }
 
  // ── Forgot password ───────────────────────────────────────────────────────
 
  void _showForgotPassword() {
    final rootMessenger = ScaffoldMessenger.of(context);
 
    _resetCtrl.text = _isValidEmail ? _emailCtrl.text.trim() : '';
    final resetFormKey = GlobalKey<FormState>();
    bool sending = false;
 
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: Form(
              key: resetFormKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 20),
 
                  Row(children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.lock_reset_rounded,
                          color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Reset password',
                          style: GoogleFonts.nunito(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textDark)),
                      Text('Enter the email you registered with',
                          style: GoogleFonts.nunito(
                              fontSize: 12, color: AppColors.textLight)),
                    ]),
                  ]),
                  const SizedBox(height: 20),
 
                  TextFormField(
                    controller:   _resetCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect:  false,
                    style: GoogleFonts.nunito(
                        fontSize: 14, color: AppColors.textDark),
                    validator: AppValidators.email,
                    decoration: InputDecoration(
                      hintText:  'you@cvsu.edu.ph or your email',
                      hintStyle: GoogleFonts.nunito(
                          color: AppColors.textLight, fontSize: 13),
                      prefixIcon: const Icon(Icons.mail_outline,
                          color: AppColors.textLight, size: 20),
                      filled:    true,
                      fillColor: AppColors.background,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.border)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.border)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.primary, width: 2)),
                      errorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.danger)),
                      focusedErrorBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.danger, width: 2)),
                    ),
                  ),
                  const SizedBox(height: 20),
 
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: sending ? null : () async {
                        if (!(resetFormKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setSheetState(() => sending = true);
 
                        final emailToSend = _resetCtrl.text.trim();
 
                        try {
                          await Supabase.instance.client.auth
                              .resetPasswordForEmail(
                            emailToSend.toLowerCase(),
                            redirectTo: 'io.supabase.bloom://reset-callback',
                          );
 
                          if (sheetCtx.mounted) {
                            Navigator.pop(sheetCtx);
                          }
 
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            rootMessenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Reset link sent to $emailToSend. '
                                  'Check your inbox.',
                                  style: GoogleFonts.nunito(color: Colors.white),
                                ),
                                backgroundColor: AppColors.primary,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          });
                        } catch (e) {
                          if (sheetCtx.mounted) {
                            setSheetState(() => sending = false);
                          }
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            rootMessenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Failed to send reset email. Please try again.',
                                  style: GoogleFonts.nunito(color: Colors.white),
                                ),
                                backgroundColor: AppColors.danger,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          });
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        disabledBackgroundColor:
                            AppColors.primary.withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: sending
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2.5))
                          : Text('Send reset link',
                              style: GoogleFonts.nunito(
                                  fontSize:   15,
                                  fontWeight: FontWeight.w800,
                                  color:      Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
 
  // ── Google sign-in (masterlist only) ──────────────────────────────────────
 
  Future<void> _handleGoogleLogin() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      // AuthService checks the masterlist and sets the role from it.
      final error = await AuthService.signInWithGoogle();
      if (!mounted) return;
 
      if (error != null) {
        if (error != 'Google sign-in cancelled.') {
          setState(() => _error = error);
        }
        return;
      }
 
      widget.onGuestLogin();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
 
  // ── Build ─────────────────────────────────────────────────────────────────
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [
 
        // ── Gradient header ────────────────────────────────────────────
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end:   Alignment.bottomRight,
              colors: [AppColors.primaryDark, AppColors.primary],
            ),
            borderRadius: BorderRadius.only(
              bottomLeft:  Radius.elliptical(220, 80),
              bottomRight: Radius.elliptical(220, 80),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(32, 64, 32, 48),
          child: Column(children: [
            Container(
              width: 76, height: 76,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3), width: 1.5)),
              child: const Center(
                child: Icon(Icons.eco_rounded, color: Colors.white, size: 36)),
            ),
            const SizedBox(height: 16),
            Text('Welcome to BLOOM',
                style: GoogleFonts.nunito(
                    color:      Colors.white,
                    fontSize:   22,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('GADRC · Cavite State University',
                style: GoogleFonts.nunito(
                    color:    Colors.white.withValues(alpha: 0.75),
                    fontSize: 13)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color:        Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border:       Border.all(
                    color: Colors.white.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.verified_user_rounded,
                      color: Colors.white, size: 14),
                  const SizedBox(width: 6),
                  Text('For CvSU & GADRC-registered participants',
                      style: GoogleFonts.nunito(
                          color:      Colors.white,
                          fontSize:   11,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ]),
        ),
 
        // ── Form body ──────────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
 
                  // ── Google button ────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _loading ? null : _handleGoogleLogin,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                            color: AppColors.textLight.withValues(alpha: 0.4)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16))),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 20, height: 20,
                            decoration: BoxDecoration(
                              color:        Colors.white,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.grey.shade300)),
                            child: const Center(
                              child: Text('G',
                                  style: TextStyle(
                                      fontSize:   13,
                                      fontWeight: FontWeight.w700,
                                      color:      Color(0xFF4285F4)))),
                          ),
                          const SizedBox(width: 10),
                          Text('Continue with Google',
                              style: GoogleFonts.nunito(
                                  fontSize:   15,
                                  fontWeight: FontWeight.w700,
                                  color:      AppColors.textDark)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Your Google email must be in the BLOOM masterlist',
                      style: GoogleFonts.nunito(
                          fontSize: 11, color: AppColors.textLight),
                    ),
                  ),
                  const SizedBox(height: 20),
 
                  // ── Divider ──────────────────────────────────────────
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or sign in with email',
                          style: GoogleFonts.nunito(
                              color: AppColors.textLight, fontSize: 13))),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 20),
 
                  // ── Error banner ─────────────────────────────────────
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color:        AppColors.danger.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: AppColors.danger.withValues(alpha: 0.3))),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.error_outline,
                              color: AppColors.danger, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_error!,
                                style: GoogleFonts.nunito(
                                    color: AppColors.danger, fontSize: 13))),
                        ]),
                    ),
                    const SizedBox(height: 16),
                  ],
 
                  // ── Email ────────────────────────────────────────────
                  _buildLabel('EMAIL'),
                  const SizedBox(height: 8),
                  _buildFormField(
                    ctrl:      _emailCtrl,
                    hint:      'you@cvsu.edu.ph or your registered email',
                    icon:      Icons.mail_outline,
                    inputType: TextInputType.emailAddress,
                    onChanged: (_) => setState(() {}),
                    validator: AppValidators.email,
                    suffix: _isCvsuEmail
                        ? const Icon(Icons.verified_outlined,
                            color: Colors.green, size: 20)
                        : null,
                  ),
                  const SizedBox(height: 16),
 
                  // ── Password ─────────────────────────────────────────
                  _buildLabel('PASSWORD'),
                  const SizedBox(height: 8),
                  _buildFormField(
                    ctrl:      _passCtrl,
                    hint:      'Enter your password',
                    icon:      Icons.lock_outline,
                    obscure:   _obscurePass,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Password is required.';
                      return null;
                    },
                    suffix: IconButton(
                      icon: Icon(
                          _obscurePass
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: AppColors.textLight, size: 20),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass)),
                    onFieldSubmitted: (_) => _handleLogin(),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: _showForgotPassword,
                      child: Text('Forgot password?',
                          style: GoogleFonts.nunito(
                              fontSize:   13,
                              fontWeight: FontWeight.w700,
                              color:      AppColors.primary)),
                    ),
                  ),
                  const SizedBox(height: 20),
 
                  // ── Sign in button ────────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppColors.primary.withValues(alpha: 0.4),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        elevation: 4,
                        shadowColor: AppColors.primary.withValues(alpha: 0.4)),
                      child: _loading
                          ? const SizedBox(
                              height: 20, width: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2.5))
                          : Text('Sign In',
                              style: GoogleFonts.nunito(
                                  fontSize:   16,
                                  fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(height: 16),
 
                  // ── Sign up link ──────────────────────────────────────
                  Center(
                    child: GestureDetector(
                      onTap: widget.onGoSignup,
                      child: RichText(
                        text: TextSpan(
                          style: GoogleFonts.nunito(
                              color: AppColors.textLight, fontSize: 13),
                          children: [
                            const TextSpan(text: "Don't have an account? "),
                            TextSpan(
                                text: 'Sign Up',
                                style: GoogleFonts.nunito(
                                    color:      AppColors.primary,
                                    fontWeight: FontWeight.w800)),
                          ]),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
 
                  // ── Info note ─────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color:        AppColors.primary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            color: AppColors.primary, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'BLOOM is for Cavite State University students and '
                            'staff, and for participants registered by the GADRC. '
                            'CvSU members use their @cvsu.edu.ph email; other '
                            'participants use the email the GADRC added to the '
                            'masterlist.',
                            style: GoogleFonts.nunito(
                                fontSize: 12,
                                color:    AppColors.textMid,
                                height:   1.5))),
                      ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }
 
  // ── Reusable field builders ───────────────────────────────────────────────
 
  Widget _buildFormField({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    bool    obscure = false,
    Widget? suffix,
    TextInputType?        inputType,
    void Function(String)? onChanged,
    void Function(String)? onFieldSubmitted,
  }) {
    return TextFormField(
      controller:       ctrl,
      obscureText:      obscure,
      keyboardType:     inputType,
      validator:        validator,
      onChanged:        onChanged,
      onFieldSubmitted: onFieldSubmitted,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      style: GoogleFonts.nunito(fontSize: 14, color: AppColors.textDark),
      decoration: InputDecoration(
        hintText:   hint,
        hintStyle:  GoogleFonts.nunito(
            color: AppColors.textLight, fontSize: 13),
        prefixIcon: Icon(icon, color: AppColors.textLight, size: 20),
        suffixIcon: suffix,
        filled:     true,
        fillColor:  Colors.white,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.primary, width: 2)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.danger)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.danger, width: 2)),
      ),
    );
  }
 
  Widget _buildLabel(String text) => Text(text,
      style: GoogleFonts.nunito(
          fontSize:      12,
          fontWeight:    FontWeight.w700,
          color:         AppColors.textMid,
          letterSpacing: 0.5));
}