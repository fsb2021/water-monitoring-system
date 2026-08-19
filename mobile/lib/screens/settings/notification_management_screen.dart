import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:water_app/screens/common/app_background.dart';
import 'package:water_app/translations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Realtime Database layout used here
//
//  users/
//    {uid}/
//      name:  "Alice"
//      email: "alice@example.com"
//      role:  "admin" | "user"
//      notifications/
//        app:       true | false
//        updatedAt: <timestamp ms>
//        updatedBy: "{admin uid}"
// ─────────────────────────────────────────────────────────────────────────────

class NotificationManagementScreen extends StatefulWidget {
  final Locale? currentLocale;
  final Function(Locale)? onLocaleChanged;

  const NotificationManagementScreen({
    super.key,
    this.currentLocale,
    this.onLocaleChanged,
  });

  @override
  State<NotificationManagementScreen> createState() =>
      _NotificationManagementScreenState();
}

class _NotificationManagementScreenState
    extends State<NotificationManagementScreen> {
  final Translations _translations = Translations();
  final DatabaseReference _db = FirebaseDatabase.instance.ref('users');

  // Local optimistic state: uid → app notif enabled
  final Map<String, bool> _appEnabled = {};
  // UIDs currently being saved
  final Set<String> _saving = {};

  String _translate(String key) {
    _translations.setLocale(widget.currentLocale ?? const Locale('en'));
    return _translations.translate(key);
  }

  // ── Toggle & persist ──────────────────────────────────────────────────────
  Future<void> _toggleApp(String uid, bool newValue) async {
    // Optimistic update
    setState(() {
      _appEnabled[uid] = newValue;
      _saving.add(uid);
    });

    try {
      await FirebaseDatabase.instance.ref('users/$uid/notifications').update({
        'app': newValue,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'updatedBy': FirebaseAuth.instance.currentUser?.uid ?? '',
      });
    } catch (e) {
      // Roll back on failure
      if (mounted) {
        setState(() => _appEnabled[uid] = !newValue);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(uid));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Column(
            children: [
              // ── Header ───────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.only(top: 20, bottom: 8, left: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios,
                          color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _translate('notif_management_title'),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w300,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Column labels ─────────────────────────────────────────────
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                child: Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    Row(
                      children: [
                        const Icon(Icons.notifications_active,
                            color: Colors.white38, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          _translate('app_notif_short'),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),

              const Divider(color: Colors.white12, height: 1),

              // ── User list streamed from Realtime Database ─────────────────
              Expanded(
                child: StreamBuilder<DatabaseEvent>(
                  stream: _db.onValue,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child:
                            CircularProgressIndicator(color: Colors.cyanAccent),
                      );
                    }

                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Error: ${snapshot.error}',
                          style: const TextStyle(color: Colors.red),
                        ),
                      );
                    }

                    final data = snapshot.data?.snapshot.value;
                    if (data == null) {
                      return Center(
                        child: Text(
                          _translate('no_users'),
                          style: const TextStyle(color: Colors.white54),
                        ),
                      );
                    }

                    // Convert the map snapshot to a sorted list
                    final usersMap = Map<String, dynamic>.from(data as Map);
                    final users = usersMap.entries
                        .map((e) => {
                              'uid': e.key,
                              ...Map<String, dynamic>.from(e.value as Map),
                            })
                        .toList()
                      ..sort((a, b) => (a['name'] as String? ?? '')
                          .compareTo(b['name'] as String? ?? ''));

                    if (users.isEmpty) {
                      return Center(
                        child: Text(
                          _translate('no_users'),
                          style: const TextStyle(color: Colors.white54),
                        ),
                      );
                    }

                    return ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      itemCount: users.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final u = users[i];
                        final uid = u['uid'] as String;
                        final name =
                            (u['name'] as String?)?.trim().isNotEmpty == true
                                ? u['name'] as String
                                : (u['email'] as String? ?? uid);
                        final email = u['email'] as String? ?? '';
                        final role = u['role'] as String? ?? 'user';
                        final isAdmin = role == 'admin';

                        // Sync from DB only when not mid-save
                        if (!_saving.contains(uid)) {
                          final notifs =
                              u['notifications'] as Map<dynamic, dynamic>?;
                          _appEnabled[uid] = notifs?['app'] == true;
                        }

                        return _buildUserTile(
                          uid: uid,
                          name: name,
                          email: email,
                          isAdmin: isAdmin,
                          appEnabled: _appEnabled[uid] ?? false,
                          isSaving: _saving.contains(uid),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── User tile ─────────────────────────────────────────────────────────────
  Widget _buildUserTile({
    required String uid,
    required String name,
    required String email,
    required bool isAdmin,
    required bool appEnabled,
    required bool isSaving,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 22,
            backgroundColor: isAdmin
                ? Colors.cyanAccent.withOpacity(0.25)
                : Colors.white.withOpacity(0.10),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: isAdmin ? Colors.cyanAccent : Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Name + email
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isAdmin) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.cyanAccent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.cyanAccent.withOpacity(0.4)),
                        ),
                        child: const Text(
                          'Admin',
                          style: TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (email.isNotEmpty)
                  Text(
                    email,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),

          // Toggle or spinner
          if (isSaving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.cyanAccent),
              ),
            )
          else
            _notifToggle(
              enabled: appEnabled,
              onTap: () => _toggleApp(uid, !appEnabled),
            ),
        ],
      ),
    );
  }

  // ── Notification toggle button ────────────────────────────────────────────
  Widget _notifToggle({
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: enabled
              ? Colors.cyanAccent.withOpacity(0.20)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? Colors.cyanAccent.withOpacity(0.60)
                : Colors.white.withOpacity(0.12),
            width: 1.5,
          ),
        ),
        child: Icon(
          Icons.notifications_active,
          size: 20,
          color: enabled ? Colors.cyanAccent : Colors.white24,
        ),
      ),
    );
  }
}
