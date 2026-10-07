// lib/screens/signup_screen.dart
// BLOOM GAD Mobile App — Signup Screen
//
// Only people in the BLOOM masterlist can create an account:
//   • CvSU students/staff with their @cvsu.edu.ph email
//   • Outsiders added by the GADRC admin (any email, e.g. Gmail)

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../services/auth_service.dart';


class SignupScreen extends StatefulWidget {
  final VoidCallback onGoLogin;

  final void Function({
    required String  email,
    required String  fullName,
    required String  role,
    required String? studentId,
    required String? department,
    required String? course,
    required int?    yearLevel,
  }) onNeedsOtp;

  final VoidCallback? onGuestSignup;

  const SignupScreen({
    super.key,
    required this.onGoLogin,
    required this.onNeedsOtp,
    this.onGuestSignup,
  });

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}


class _SignupScreenState extends State<SignupScreen> {
  final _formKey       = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl  = TextEditingController();
  final _emailCtrl     = TextEditingController();
  final _passCtrl      = TextEditingController();
  final _confirmCtrl   = TextEditingController();

  bool    _obscurePass    = true;
  bool    _obscureConfirm = true;
  bool    _loading        = false;
  String? _error;
  String? _sex;            // 'female' | 'male' — for sex-disaggregated (SDD) reports
  bool    _sexError       = false;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _isCvsuEmail =>
      RegExp(r'^[^@]+@cvsu\.edu\.ph$')
          .hasMatch(_emailCtrl.text.trim().toLowerCase());

  Future<void> _handleSignup() async {
    if (_loading) return;
    setState(() => _error = null);

    final formOk = _formKey.currentState!.validate();
    if (_sex == null) setState(() => _sexError = true);
    if (!formOk || _sex == null) return;

    setState(() => _loading = true);

    final cleanEmail = AppValidators.normalizeEmail(_emailCtrl.text);

    // ── Guard 1: masterlist check (CvSU emails AND admin-added outsiders) ──
    final masterlistError = await AuthService.checkMasterlist(cleanEmail);
    if (!mounted) return;
    if (masterlistError != null) {
      setState(() { _error = masterlistError; _loading = false; });
      return;
    }

    // ── Guard 2: duplicate account check ──────────────────────────────
    final duplicateError = await AuthService.checkEmailAlreadyRegistered(cleanEmail);
    if (!mounted) return;
    if (duplicateError != null) {
      setState(() { _error = duplicateError; _loading = false; });
      return;
    }

    // ── Fetch masterlist entry to pass to OtpScreen ───────────────────
    final entry = await AuthService.getMasterlistEntry(cleanEmail);
    if (!mounted) return;

    // ── Guard 3: create Supabase Auth user + send OTP ─────────────────
    final fullName = '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}';

    final error = await AuthService.signUp(
      email:     cleanEmail,
      password:  _passCtrl.text,
      fullName:  fullName,
      studentId: '',
      sex:       _sex,
    );

    if (!mounted) return;

    if (error != null) {
      setState(() { _error = error; _loading = false; });
      return;
    }

    widget.onNeedsOtp(
      email:      cleanEmail,
      fullName:   fullName,
      role:       entry?['role']       as String?  ?? '',
      studentId:  entry?['student_id'] as String?,
      department: entry?['department'] as String?,
      course:     entry?['course']     as String?,
      yearLevel:  entry?['year_level'] as int?,
    );
  }

  Future<void> _handleGoogleSignup() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      // AuthService checks the masterlist and sets the role from it.
      final error = await AuthService.signInWithGoogle();
      if (!mounted) return;

      if (error != null) {
        if (error != 'Google sign-in cancelled.') setState(() => _error = error);
        return;
      }

      (widget.onGuestSignup ?? widget.onGoLogin)();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(children: [

        // ── Header ────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primaryDark, AppColors.primary],
            ),
            borderRadius: BorderRadius.only(
              bottomLeft:  Radius.elliptical(220, 80),
              bottomRight: Radius.elliptical(220, 80),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(32, 64, 32, 48),
          child: Column(children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: widget.onGoLogin,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.all(10),
                  child: const Icon(Icons.chevron_left,
                      color: Colors.white, size: 22)),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: 76, height: 76,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3), width: 1.5)),
              child: const Center(
                child: Icon(Icons.diversity_3_rounded,
                    color: Colors.white, size: 36)),
            ),
            const SizedBox(height: 16),
            Text('Create Account',
                style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('Join the GADRC CvSU community',
                style: GoogleFonts.nunito(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13)),
          ]),
        ),

        // ── Form ──────────────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── Google button ───────────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _loading ? null : _handleGoogleSignup,
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
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.grey.shade300)),
                            child: const Center(
                              child: Text('G',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF4285F4)))),
                          ),
                          const SizedBox(width: 10),
                          Text('Continue with Google',
                              style: GoogleFonts.nunito(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textDark)),
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

                  // ── Divider ─────────────────────────────────────────
                  Row(children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('or sign up with email',
                          style: GoogleFonts.nunito(
                              color: AppColors.textLight, fontSize: 13))),
                    const Expanded(child: Divider()),
                  ]),
                  const SizedBox(height: 20),

                  // ── Error banner ────────────────────────────────────
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withValues(alpha: 0.08),
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
                                    color: AppColors.danger, fontSize: 13)),
                          ),
                        ]),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // ── Full name ────────────────────────────────────────
                  _buildLabel('FULL NAME'),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildFormField(
                        ctrl:      _firstNameCtrl,
                        hint:      'First name',
                        icon:      Icons.person_outline,
                        validator: (v) => AppValidators.name(v, field: 'First name'),
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: _buildFormField(
                        ctrl:      _lastNameCtrl,
                        hint:      'Last name',
                        icon:      Icons.person_outline,
                        validator: (v) => AppValidators.name(v, field: 'Last name'),
                      )),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // ── Sex (for GAD sex-disaggregated data) ─────────────
                  _buildLabel('SEX'),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _sexOption('female', 'Female', Icons.female_rounded)),
                    const SizedBox(width: 10),
                    Expanded(child: _sexOption('male', 'Male', Icons.male_rounded)),
                  ]),
                  if (_sexError) ...[
                    const SizedBox(height: 6),
                    Text('Please select your sex.',
                        style: GoogleFonts.nunito(fontSize: 12, color: AppColors.danger)),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    'Used only for GAD sex-disaggregated reports.',
                    style: GoogleFonts.nunito(fontSize: 11, color: AppColors.textLight),
                  ),
                  const SizedBox(height: 16),

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
                  const SizedBox(height: 6),
                  Text(
                    'CvSU members: use your @cvsu.edu.ph email. '
                    'Other participants: use the email the GADRC added to the masterlist.',
                    style: GoogleFonts.nunito(
                        fontSize: 11, color: AppColors.textLight, height: 1.4),
                  ),
                  const SizedBox(height: 14),

                  // ── Password ─────────────────────────────────────────
                  _buildLabel('PASSWORD'),
                  const SizedBox(height: 8),
                  _buildFormField(
                    ctrl:      _passCtrl,
                    hint:      'Min. 8 chars, uppercase, number, symbol',
                    icon:      Icons.lock_outline,
                    obscure:   _obscurePass,
                    validator: AppValidators.password,
                    onChanged: (_) => setState(() {}),
                    suffix: IconButton(
                      icon: Icon(
                          _obscurePass
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: AppColors.textLight, size: 20),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass)),
                  ),
                  _buildStrengthBar(_passCtrl.text),
                  const SizedBox(height: 16),

                  // ── Confirm password ─────────────────────────────────
                  _buildLabel('CONFIRM PASSWORD'),
                  const SizedBox(height: 8),
                  _buildFormField(
                    ctrl:      _confirmCtrl,
                    hint:      'Re-enter password',
                    icon:      Icons.lock_outline,
                    obscure:   _obscureConfirm,
                    validator: (v) =>
                        AppValidators.confirmPassword(v, _passCtrl.text),
                    suffix: IconButton(
                      icon: Icon(
                          _obscureConfirm
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: AppColors.textLight, size: 20),
                      onPressed: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm)),
                  ),
                  const SizedBox(height: 20),

                  // ── Info note ─────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            color: AppColors.primary, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'A 6-digit verification code will be sent to your '
                            'email. After verifying, you\'ll be taken directly '
                            'to the Home screen.',
                            style: GoogleFonts.nunito(
                                fontSize: 12,
                                color: AppColors.textMid,
                                height: 1.5))),
                      ]),
                  ),
                  const SizedBox(height: 20),

                  // ── Create Account button ─────────────────────────────
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _handleSignup,
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
                          : Text('Create Account',
                              style: GoogleFonts.nunito(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Sign in link ──────────────────────────────────────
                  Center(
                    child: GestureDetector(
                      onTap: widget.onGoLogin,
                      child: RichText(
                        text: TextSpan(
                          style: GoogleFonts.nunito(
                              color: AppColors.textLight, fontSize: 13),
                          children: [
                            const TextSpan(text: 'Already have an account? '),
                            TextSpan(
                                text: 'Sign In',
                                style: GoogleFonts.nunito(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w800)),
                          ]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _sexOption(String value, String label, IconData icon) {
    final selected = _sex == value;
    return GestureDetector(
      onTap: () => setState(() { _sex = value; _sexError = false; }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : (_sexError ? AppColors.danger : AppColors.border),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 18, color: selected ? AppColors.primary : AppColors.textLight),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.nunito(
              fontSize: 14, fontWeight: FontWeight.w700,
              color: selected ? AppColors.primary : AppColors.textMid)),
        ]),
      ),
    );
  }

  Widget _buildStrengthBar(String password) {
    if (password.isEmpty) return const SizedBox(height: 6);
    final score  = AppValidators.passwordStrength(password);
    final colors = [
      Colors.transparent, Colors.red, Colors.red,
      Colors.orange, Colors.lightGreen, Colors.green,
    ];
    final labels = ['', 'Very Weak', 'Weak', 'Fair', 'Good', 'Strong'];
    final color  = score < colors.length ? colors[score] : Colors.green;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 8),
      Row(children: List.generate(5, (i) => Expanded(
          child: Container(
            height: 4,
            margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
            decoration: BoxDecoration(
              color: i < score ? color : AppColors.border,
              borderRadius: BorderRadius.circular(2)))))),
      const SizedBox(height: 4),
      Text(score > 0 ? labels[score] : '',
          style: GoogleFonts.nunito(
              fontSize: 11, color: color, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _buildFormField({
    required TextEditingController ctrl,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    bool obscure = false,
    Widget? suffix,
    TextInputType? inputType,
    void Function(String)? onChanged,
  }) {
    return TextFormField(
      controller:       ctrl,
      obscureText:      obscure,
      keyboardType:     inputType,
      validator:        validator,
      onChanged:        onChanged,
      style: GoogleFonts.nunito(fontSize: 14, color: AppColors.textDark),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      decoration: InputDecoration(
        hintText:   hint,
        hintStyle:  GoogleFonts.nunito(color: AppColors.textLight, fontSize: 13),
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

  Widget _buildLabel(String text) {
    return Text(text,
        style: GoogleFonts.nunito(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textMid,
            letterSpacing: 0.5));
  }
}