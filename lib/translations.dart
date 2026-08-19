import 'package:flutter/material.dart';

class Translations {
  static final Translations _instance = Translations._internal();

  factory Translations() {
    return _instance;
  }

  Translations._internal();

  Locale _currentLocale = const Locale('en');

  Locale get currentLocale => _currentLocale;

  void setLocale(Locale locale) {
    _currentLocale = locale;
  }

  String getLanguageName(Locale locale) {
    switch (locale.languageCode) {
      case 'fr':
        return 'français';
      case 'ar':
        return 'العربية';
      case 'de':
        return 'deutsch';
      default:
        return 'english';
    }
  }

  Locale getLocaleFromName(String name) {
    switch (name) {
      case 'français':
        return const Locale('fr');
      case 'العربية':
        return const Locale('ar');
      case 'deutsch':
        return const Locale('de');
      default:
        return const Locale('en');
    }
  }

  String translate(String key) {
    final code = _currentLocale.languageCode;

    final translations = {
      'settings': {
        'en': 'settings',
        'fr': 'paramètres',
        'ar': 'إعدادات',
        'de': 'Einstellungen',
      },
      'measure_delay': {
        'en': 'measure delay',
        'fr': 'délai de mesure',
        'ar': 'تأخير القياس',
        'de': 'Messverzögerung',
      },
      'language': {
        'en': 'language',
        'fr': 'langue',
        'ar': 'اللغة',
        'de': 'Sprache',
      },
      'app_notification': {
        'en': 'app notification',
        'fr': 'notification app',
        'ar': 'إشعار التطبيق',
        'de': 'App-Benachrichtigung',
      },
      'sms_notification': {
        'en': 'sms notification',
        'fr': 'notification sms',
        'ar': 'إشعار SMS',
        'de': 'SMS-Benachrichtigung',
      },
      'disconnected': {
        'en': 'disconnected',
        'fr': 'déconnecté',
        'ar': 'غير متصل',
        'de': 'getrennt',
      },
      'dashboard': {
        'en': 'Dashboard',
        'fr': 'Tableau de bord',
        'ar': 'لوحة التحكم',
        'de': 'Armaturenbrett',
      },
      'charts': {
        'en': 'Charts',
        'fr': 'Graphiques',
        'ar': 'الرسوم البيانية',
        'de': 'Diagramme',
      },
      'cooling_recommendation': {
        'en': 'Cooling System Analysis',
        'fr': 'Analyse du système de refroidissement',
        'ar': 'تحليل نظام التبريد',
        'de': 'Analyse des Kühlsystems',
      },
      'efficiency_score': {
        'en': 'Efficiency Score',
        'fr': 'Score d\'efficacité',
        'ar': 'درجة الكفاءة',
        'de': 'Effizienzwert',
      },
      'sensor_readings': {
        'en': 'Sensor Readings',
        'fr': 'Lectures des capteurs',
        'ar': 'قراءات المستشعرات',
        'de': 'Sensormesswerte',
      },
      'chat_with_ai': {
        'en': 'Chat with AI',
        'fr': 'Discuter avec l\'IA',
        'ar': 'الدردشة مع الذكاء الاصطناعي',
        'de': 'Mit KI chatten',
      },
      'temperature': {
        'en': 'Temperature',
        'fr': 'Température',
        'ar': 'درجة الحرارة',
        'de': 'Temperatur',
      },
      'turbidity': {
        'en': 'Turbidity',
        'fr': 'Turbidité',
        'ar': 'العكارة',
        'de': 'Trübung',
      },
      'conductivity': {
        'en': 'Conductivity',
        'fr': 'Conductivité',
        'ar': 'التوصيلية',
        'de': 'Leitfähigkeit',
      },
      'status': {
        'en': 'Status',
        'fr': 'Statut',
        'ar': 'الحالة',
        'de': 'Status',
      },
      'last_update': {
        'en': 'Last update',
        'fr': 'Dernière mise à jour',
        'ar': 'آخر تحديث',
        'de': 'Letztes Update',
      },
      'ask_about_cooling': {
        'en': 'Ask about cooling...',
        'fr': 'Posez une question sur le refroidissement...',
        'ar': 'اسأل عن التبريد...',
        'de': 'Fragen Sie etwas zur Kühlung...',
      },
      'login_title': {
        'en': 'Log in to your Account',
        'fr': 'Connectez-vous à votre compte',
        'ar': 'سجّل الدخول إلى حسابك',
        'de': 'Melden Sie sich bei Ihrem Konto an',
      },
      'email': {
        'en': 'Email',
        'fr': 'E-mail',
        'ar': 'البريد الإلكتروني',
        'de': 'E-Mail',
      },
      'password': {
        'en': 'Password',
        'fr': 'Mot de passe',
        'ar': 'كلمة المرور',
        'de': 'Passwort',
      },
      'login': {
        'en': 'Log in',
        'fr': 'Se connecter',
        'ar': 'تسجيل الدخول',
        'de': 'Anmelden',
      },
      'dont_have_account_signup': {
        'en': 'Don\'t have an account? Sign Up',
        'fr': 'Vous n\'avez pas de compte ? Inscrivez-vous',
        'ar': 'ليس لديك حساب؟ أنشئ حسابًا',
        'de': 'Noch kein Konto? Registrieren',
      },
      'or': {
        'en': 'OR',
        'fr': 'OU',
        'ar': 'أو',
        'de': 'ODER',
      },
      'continue_google': {
        'en': 'Continue with Google',
        'fr': 'Continuer avec Google',
        'ar': 'المتابعة باستخدام Google',
        'de': 'Mit Google fortfahren',
      },
      'create_account': {
        'en': 'Create your Account',
        'fr': 'Créez votre compte',
        'ar': 'أنشئ حسابك',
        'de': 'Erstellen Sie Ihr Konto',
      },
      'full_name': {
        'en': 'Full Name',
        'fr': 'Nom complet',
        'ar': 'الاسم الكامل',
        'de': 'Vollständiger Name',
      },
      'confirm_password': {
        'en': 'Confirm Password',
        'fr': 'Confirmer le mot de passe',
        'ar': 'تأكيد كلمة المرور',
        'de': 'Passwort bestätigen',
      },
      'sign_up': {
        'en': 'Sign Up',
        'fr': 'S\'inscrire',
        'ar': 'إنشاء حساب',
        'de': 'Registrieren',
      },
      'already_have_account_login': {
        'en': 'Already have an account? Log in',
        'fr': 'Vous avez déjà un compte ? Connectez-vous',
        'ar': 'لديك حساب بالفعل؟ سجّل الدخول',
        'de': 'Sie haben bereits ein Konto? Anmelden',
      },
      'sign_up_google': {
        'en': 'Sign up with Google',
        'fr': 'S\'inscrire avec Google',
        'ar': 'إنشاء حساب باستخدام Google',
        'de': 'Mit Google registrieren',
      },
      'enable': {
        'en': 'enable',
        'fr': 'activer',
        'ar': 'تفعيل',
        'de': 'aktivieren',
      },
      'disable': {
        'en': 'disable',
        'fr': 'désactiver',
        'ar': 'تعطيل',
        'de': 'deaktivieren',
      },
      'disconnect_title': {
        'en': 'Disconnect',
        'fr': 'Déconnexion',
        'ar': 'قطع الاتصال',
        'de': 'Trennen',
      },
      'disconnect_confirm': {
        'en': 'Are you sure you want to disconnect from the device?',
        'fr': 'Voulez-vous vraiment vous déconnecter de l\'appareil ?',
        'ar': 'هل أنت متأكد أنك تريد قطع الاتصال بالجهاز؟',
        'de': 'Möchten Sie die Verbindung zum Gerät wirklich trennen?',
      },
      'cancel': {
        'en': 'Cancel',
        'fr': 'Annuler',
        'ar': 'إلغاء',
        'de': 'Abbrechen',
      },
      'disconnect': {
        'en': 'Disconnect',
        'fr': 'Déconnecter',
        'ar': 'قطع الاتصال',
        'de': 'Trennen',
      },
      'disconnect_success': {
        'en': 'Disconnected successfully',
        'fr': 'Déconnecté avec succès',
        'ar': 'تم قطع الاتصال بنجاح',
        'de': 'Erfolgreich getrennt',
      },
      'passwords_do_not_match': {
        'en': 'Passwords do not match',
        'fr': 'Les mots de passe ne correspondent pas',
        'ar': 'كلمتا المرور غير متطابقتين',
        'de': 'Passwörter stimmen nicht überein',
      },
      'login_failed': {
        'en': 'Login failed',
        'fr': 'Échec de la connexion',
        'ar': 'فشل تسجيل الدخول',
        'de': 'Anmeldung fehlgeschlagen',
      },
      'google_signin_failed': {
        'en': 'Google sign in failed',
        'fr': 'Échec de la connexion Google',
        'ar': 'فشل تسجيل الدخول عبر Google',
        'de': 'Google-Anmeldung fehlgeschlagen',
      },
      'signup_failed': {
        'en': 'Sign up failed',
        'fr': 'Échec de l\'inscription',
        'ar': 'فشل إنشاء الحساب',
        'de': 'Registrierung fehlgeschlagen',
      },
      'google_signup_failed': {
        'en': 'Google sign up failed',
        'fr': 'Échec de l\'inscription Google',
        'ar': 'فشل إنشاء الحساب عبر Google',
        'de': 'Google-Registrierung fehlgeschlagen',
      },
      'auth_invalid_email': {
        'en': 'Invalid email address',
        'fr': 'Adresse e-mail invalide',
        'ar': 'عنوان البريد الإلكتروني غير صالح',
        'de': 'Ungültige E-Mail-Adresse',
      },
      'auth_user_disabled': {
        'en': 'This account has been disabled',
        'fr': 'Ce compte a été désactivé',
        'ar': 'تم تعطيل هذا الحساب',
        'de': 'Dieses Konto wurde deaktiviert',
      },
      'auth_user_not_found': {
        'en': 'No user found for this email',
        'fr': 'Aucun utilisateur trouvé pour cet e-mail',
        'ar': 'لا يوجد مستخدم لهذا البريد الإلكتروني',
        'de': 'Kein Benutzer für diese E-Mail gefunden',
      },
      'auth_wrong_password': {
        'en': 'Incorrect password',
        'fr': 'Mot de passe incorrect',
        'ar': 'كلمة المرور غير صحيحة',
        'de': 'Falsches Passwort',
      },
      'auth_email_already_in_use': {
        'en': 'This email is already in use',
        'fr': 'Cet e-mail est déjà utilisé',
        'ar': 'هذا البريد الإلكتروني مستخدم بالفعل',
        'de': 'Diese E-Mail wird bereits verwendet',
      },
      'auth_weak_password': {
        'en': 'Password is too weak',
        'fr': 'Le mot de passe est trop faible',
        'ar': 'كلمة المرور ضعيفة جدًا',
        'de': 'Passwort ist zu schwach',
      },
      'auth_operation_not_allowed': {
        'en': 'Operation is not allowed',
        'fr': 'Opération non autorisée',
        'ar': 'العملية غير مسموح بها',
        'de': 'Vorgang ist nicht erlaubt',
      },
      'auth_unknown_error': {
        'en': 'Unknown authentication error',
        'fr': 'Erreur d\'authentification inconnue',
        'ar': 'خطأ مصادقة غير معروف',
        'de': 'Unbekannter Authentifizierungsfehler',
      },
    };

    if (translations.containsKey(key)) {
      return translations[key]?[code] ?? translations[key]?['en'] ?? key;
    }
    return key;
  }
}
