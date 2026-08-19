import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'login_screen.dart';
import 'package:water_app/screens/monitoring/dashboard_screen.dart';

class SplashScreen extends StatelessWidget {
  final Locale currentLocale;
  final Function(Locale) onLocaleChanged;

  const SplashScreen({
    super.key,
    required this.currentLocale,
    required this.onLocaleChanged,
  });

  // Reusable animated loading screen
  Widget _buildLoadingScreen() {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 15, 113, 178),
      body: Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 850),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Opacity(
              // ✅ FIXED: Clamp the value to prevent the exact assertion error you saw
              // (opacity must always be between 0.0 and 1.0)
              opacity: value.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.85 + (0.15 * value),
                child: child,
              ),
            );
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 108,
                height: 108,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(
                  Icons.water_drop,
                  color: Colors.white,
                  size: 62,
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                'Welcome',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 7,
              ),
              const SizedBox(height: 40),
              const Text(
                'water monitoring system',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please wait until the data is loading...',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 300,
                child: LinearProgressIndicator(
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  backgroundColor: Colors.white24,
                  minHeight: 9,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _getUserRole(User user) async {
    try {
      final DatabaseReference userRef =
          FirebaseDatabase.instance.ref('users/${user.uid}');
      final DataSnapshot snapshot = await userRef.get();

      if (!snapshot.exists) {
        await userRef.set({
          'uid': user.uid,
          'name': user.displayName ?? '',
          'email': user.email ?? '',
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
    } catch (_) {
      return 'user';
    }

    return 'user';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoadingScreen();
        }

        if (snapshot.hasError) {
          return _buildLoadingScreen();
        }

        if (snapshot.hasData) {
          return FutureBuilder<String>(
            future: _getUserRole(snapshot.data!),
            builder: (context, roleSnapshot) {
              if (!roleSnapshot.hasData) {
                return _buildLoadingScreen();
              }

              if (roleSnapshot.hasError) {
                return _buildLoadingScreen();
              }

              final String role = roleSnapshot.data!;

              if (role == 'admin') {
                return DashboardScreen(
                  currentLocale: currentLocale,
                  onLocaleChanged: onLocaleChanged,
                );
              }

              return DashboardScreen(
                currentLocale: currentLocale,
                onLocaleChanged: onLocaleChanged,
              );
            },
          );
        } else {
          return LoginScreen(
            currentLocale: currentLocale,
            onLocaleChanged: onLocaleChanged,
          );
        }
      },
    );
  }
}
