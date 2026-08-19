import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:water_app/screens/monitoring/dashboard_screen.dart';
import 'package:water_app/screens/notifications/push_notification.dart';
import 'package:water_app/translations.dart';
import 'signup_screen.dart';
import 'package:water_app/screens/common/app_background.dart';

class LoginScreen extends StatefulWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const LoginScreen({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final Translations _translations = Translations();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<String> _getUserRole(User user) async {
    final DatabaseReference userRef =
        FirebaseDatabase.instance.ref('users/${user.uid}');
    final DataSnapshot snapshot = await userRef.get();

    if (!snapshot.exists) {
      await userRef.set({
        'uid': user.uid,
        'name': user.displayName ?? '',
        'email': user.email ?? _emailController.text.trim(),
        'role': 'user',
        'createdAt': ServerValue.timestamp,
        'lastLoginAt': ServerValue.timestamp,
      });
      return 'user';
    }

    final dynamic value = snapshot.value;
    if (value is Map) {
      final String role = (value['role']?.toString() ?? 'user').toLowerCase();
      await userRef.update({'lastLoginAt': ServerValue.timestamp});
      return role;
    }

    return 'user';
  }

  void _goToRoleHome(String role) {
    if (!mounted) return;

    final Widget screen = role == 'admin'
        ? DashboardScreen(
            currentLocale: widget.currentLocale,
            onLocaleChanged: widget.onLocaleChanged,
          )
        : DashboardScreen(
            currentLocale: widget.currentLocale,
            onLocaleChanged: widget.onLocaleChanged,
          );

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  String _tr(String key) {
    _translations.setLocale(Localizations.localeOf(context));
    return _translations.translate(key);
  }

  String _authErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return _tr('auth_invalid_email');
      case 'user-disabled':
        return _tr('auth_user_disabled');
      case 'user-not-found':
        return _tr('auth_user_not_found');
      case 'wrong-password':
      case 'invalid-credential':
        return _tr('auth_wrong_password');
      case 'operation-not-allowed':
        return _tr('auth_operation_not_allowed');
      default:
        return _tr('auth_unknown_error');
    }
  }

  // === EMAIL LOGIN (your existing code) ===
  Future<void> _login() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final UserCredential credential =
          await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      final User? user = credential.user;
      if (user == null) {
        throw FirebaseAuthException(code: 'auth_unknown_error');
      }

      final String role = await _getUserRole(user);
      await PushNotificationService.instance.init();
      _goToRoleHome(role);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('${_tr('login_failed')}: ${_authErrorMessage(e)}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('${_tr('login_failed')}: ${_tr('auth_unknown_error')}')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // === GOOGLE SIGN IN (STABLE v6.2.1 VERSION) ===
  Future<void> _signInWithGoogle() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        serverClientId:
            "113285381450-4c1aj72mjr2udvvv5t4tguhmraratgvi.apps.googleusercontent.com", // ← your real ID
      );

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();

      if (googleUser == null) {
        if (!mounted) return;
        setState(() => _isLoading = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final User? user = userCredential.user;

      if (user == null) {
        throw FirebaseAuthException(code: 'auth_unknown_error');
      }

      final String role = await _getUserRole(user);
      await PushNotificationService.instance.init();
      _goToRoleHome(role);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('${_tr('google_signin_failed')}: ${_authErrorMessage(e)}'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${_tr('google_signin_failed')}: ${_tr('auth_unknown_error')}'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _tr('login_title'),
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 30),

              // Email & Password fields (same as before)
              TextField(
                  controller: _emailController,
                  decoration: InputDecoration(
                      labelText: _tr('email'),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)))),
              const SizedBox(height: 15),
              TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                      labelText: _tr('password'),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)))),
              const SizedBox(height: 25),

              // Log in button
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color.fromARGB(255, 153, 183, 232),
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                onPressed: _isLoading ? null : _login,
                child: _isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(_tr('login')),
              ),

              // Sign Up link
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SignUpScreen(
                      currentLocale: widget.currentLocale,
                      onLocaleChanged: widget.onLocaleChanged,
                    ),
                  ),
                ),
                child: Text(_tr('dont_have_account_signup'),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 16)),
              ),

              // === NEW GOOGLE BUTTON ===
              const SizedBox(height: 10),
              Text(_tr('or'), style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 10),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isLoading ? null : _signInWithGoogle,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.g_mobiledata,
                        color: Colors.blue, size: 28), // Google-style icon
                    SizedBox(width: 12),
                    Text(_tr('continue_google'),
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              // ========================
            ],
          ),
        ),
      ),
    );
  }
}
