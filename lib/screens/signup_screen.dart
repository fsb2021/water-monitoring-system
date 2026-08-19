import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dashboard_screen.dart';
import 'app_background.dart';
import '../translations.dart';

class SignUpScreen extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const SignUpScreen({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final Translations _translations = Translations();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  String _selectedRole = 'user';
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  // ─── Helpers ────────────────────────────────────────────────────────────────

  String _tr(String key) {
    _translations.setLocale(Localizations.localeOf(context));
    return _translations.translate(key);
  }

  String _authErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return _tr('auth_invalid_email');
      case 'email-already-in-use':
        return _tr('auth_email_already_in_use');
      case 'weak-password':
        return _tr('auth_weak_password');
      case 'operation-not-allowed':
        return _tr('auth_operation_not_allowed');
      default:
        return _tr('auth_unknown_error');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ─── Save user to Realtime Database ─────────────────────────────────────────

  /// Saves the user profile. If the node already exists (returning user),
  /// only the lastLoginAt timestamp is updated — role is preserved.
  /// For brand-new users [role] is written as supplied.
  Future<void> _saveUserProfile(User user, {required String role}) async {
    final DatabaseReference userRef =
        FirebaseDatabase.instance.ref('users/${user.uid}');
    final DataSnapshot snapshot = await userRef.get();

    if (snapshot.exists) {
      // Returning user — just refresh the login timestamp
      await userRef.update({'lastLoginAt': ServerValue.timestamp});
      return;
    }

    // New user — write everything including the chosen role
    await userRef.set({
      'uid': user.uid,
      'name': _nameController.text.trim().isNotEmpty
          ? _nameController.text.trim()
          : (user.displayName ?? user.email?.split('@').first ?? 'User'),
      'email': user.email ?? _emailController.text.trim(),
      'role': role,
      'createdAt': ServerValue.timestamp,
      'lastLoginAt': ServerValue.timestamp,
    });
  }

  // ─── Role picker dialog (used for Google sign-up) ───────────────────────────

  Future<String?> _showRolePickerDialog() {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Select Your Role',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _roleOption(ctx, 'user', Icons.person, 'User',
                'Standard access to the dashboard'),
            const SizedBox(height: 8),
            _roleOption(ctx, 'admin', Icons.admin_panel_settings, 'Admin',
                'Full access including management tools'),
          ],
        ),
      ),
    );
  }

  Widget _roleOption(BuildContext ctx, String value, IconData icon,
      String label, String desc) {
    return ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      tileColor: Colors.grey.shade100,
      leading: Icon(icon, color: value == 'admin' ? Colors.red : Colors.blue),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(desc, style: const TextStyle(fontSize: 12)),
      onTap: () => Navigator.pop(ctx, value),
    );
  }

  // ─── Navigate to dashboard ──────────────────────────────────────────────────

  void _goToDashboard() {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => DashboardScreen(
          currentLocale: widget.currentLocale,
          onLocaleChanged: widget.onLocaleChanged,
        ),
      ),
    );
  }

  // ─── Email sign-up ──────────────────────────────────────────────────────────

  Future<void> _signUp() async {
    if (_nameController.text.trim().isEmpty) {
      _showSnack('${_tr('full_name')} is required');
      return;
    }
    if (_passwordController.text != _confirmPasswordController.text) {
      _showSnack(_tr('passwords_do_not_match'));
      return;
    }

    setState(() => _isLoading = true);

    try {
      final UserCredential cred =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      if (cred.user != null) {
        await _saveUserProfile(cred.user!, role: _selectedRole);
      }

      _goToDashboard();
    } on FirebaseAuthException catch (e) {
      _showSnack('${_tr('signup_failed')}: ${_authErrorMessage(e)}');
    } catch (_) {
      _showSnack('${_tr('signup_failed')}: ${_tr('auth_unknown_error')}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Google sign-up ─────────────────────────────────────────────────────────

  Future<void> _signUpWithGoogle() async {
    setState(() => _isLoading = true);

    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        serverClientId:
            "113285381450-4c1aj72mjr2udvvv5t4tguhmraratgvi.apps.googleusercontent.com",
      );

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential cred =
          await FirebaseAuth.instance.signInWithCredential(credential);

      if (cred.user != null) {
        final bool isNewUser = cred.additionalUserInfo?.isNewUser ?? false;
        String roleToSave = 'user';

        if (isNewUser) {
          // Pause loading indicator while showing dialog
          if (mounted) setState(() => _isLoading = false);
          final chosen = await _showRolePickerDialog();
          roleToSave = chosen ?? 'user';
          if (mounted) setState(() => _isLoading = true);
        }

        await _saveUserProfile(cred.user!, role: roleToSave);
      }

      _goToDashboard();
    } on FirebaseAuthException catch (e) {
      _showSnack('${_tr('google_signup_failed')}: ${_authErrorMessage(e)}');
    } catch (_) {
      _showSnack(
          '${_tr('google_signup_failed')}: ${_tr('auth_unknown_error')}');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Text(
                _tr('create_account'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 30),

              // ── Full Name ──────────────────────────────────────────────────
              _buildTextField(
                controller: _nameController,
                label: _tr('full_name'),
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 14),

              // ── Email ──────────────────────────────────────────────────────
              _buildTextField(
                controller: _emailController,
                label: _tr('email'),
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 14),

              // ── Password ───────────────────────────────────────────────────
              _buildTextField(
                controller: _passwordController,
                label: _tr('password'),
                icon: Icons.lock_outline,
                obscure: _obscurePassword,
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              const SizedBox(height: 14),

              // ── Confirm Password ───────────────────────────────────────────
              _buildTextField(
                controller: _confirmPasswordController,
                label: _tr('confirm_password'),
                icon: Icons.lock_outline,
                obscure: _obscureConfirm,
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirm
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              const SizedBox(height: 14),

              // ── Role Dropdown ──────────────────────────────────────────────
              DropdownButtonFormField<String>(
                initialValue: _selectedRole,
                decoration: InputDecoration(
                  labelText: 'Role',
                  prefixIcon: const Icon(Icons.badge_outlined),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'user',
                    child: Row(children: [
                      Icon(Icons.person, size: 18, color: Colors.blue),
                      SizedBox(width: 8),
                      Text('User'),
                    ]),
                  ),
                  DropdownMenuItem(
                    value: 'admin',
                    child: Row(children: [
                      Icon(Icons.admin_panel_settings,
                          size: 18, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Admin'),
                    ]),
                  ),
                ],
                onChanged: _isLoading
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _selectedRole = value);
                        }
                      },
              ),
              const SizedBox(height: 24),

              // ── Sign Up Button ─────────────────────────────────────────────
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF99B7E8),
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isLoading ? null : _signUp,
                child: _isLoading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : Text(
                        _tr('sign_up'),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
              ),
              const SizedBox(height: 14),

              // ── Already have account ───────────────────────────────────────
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  _tr('already_have_account_login'),
                  style: const TextStyle(color: Colors.white70),
                ),
              ),

              // ── Divider ────────────────────────────────────────────────────
              Row(children: [
                const Expanded(child: Divider(color: Colors.white38)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(_tr('or'),
                      style: const TextStyle(color: Colors.white70)),
                ),
                const Expanded(child: Divider(color: Colors.white38)),
              ]),
              const SizedBox(height: 14),

              // ── Google Button ──────────────────────────────────────────────
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                ),
                onPressed: _isLoading ? null : _signUpWithGoogle,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.g_mobiledata,
                        color: Colors.blue, size: 28),
                    const SizedBox(width: 10),
                    Text(
                      _tr('sign_up_google'),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
