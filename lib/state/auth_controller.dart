import 'package:flutter/foundation.dart';

import '../data/auth_api.dart';
import '../data/token_storage.dart';
import '../models/auth_user.dart';

/// Where the app is in the sign-in lifecycle.
enum AuthStatus {
  /// Restoring a stored session. The router holds on a splash rather than
  /// flashing the sign-in screen at someone who is already signed in.
  restoring,

  signedOut,
  signedIn,
}

/// The one owner of authentication state (§23).
///
/// Mirrors how `InventoryController` works — a `ChangeNotifier` behind
/// `provider`, holding the in-memory view and the only thing that mutates it —
/// so there is one state pattern in the app rather than two.
///
/// Nothing else in the app calls [AuthApi] for credentials. Widgets read
/// [user], [can] and [status]; they never see a token.
class AuthController extends ChangeNotifier {
  AuthController({required this.api}) {
    // A refresh that fails while the app is idle must not leave the UI
    // believing it is still signed in.
    api.onSessionLost = _onSessionLost;
  }

  final AuthApi api;

  AuthStatus _status = AuthStatus.restoring;
  AuthStatus get status => _status;

  AuthUser? _user;
  AuthUser? get user => _user;

  bool get isAuthenticated => _status == AuthStatus.signedIn && _user != null;
  bool get isRestoring => _status == AuthStatus.restoring;

  bool _busy = false;

  /// True while a sign-in or sign-out is in flight, for button spinners.
  bool get isBusy => _busy;

  /// Set when a session ended by itself rather than by the user asking, so the
  /// sign-in screen can explain why they are looking at it.
  String? _endedReason;
  String? get endedReason => _endedReason;

  /// Where the user was heading when they were bounced to sign-in, so they can
  /// be returned there afterwards (§5).
  String? pendingRedirect;

  // -------------------------------------------------------------------
  // Permissions (§23)
  // -------------------------------------------------------------------

  Set<String> get permissions => _user?.permissions ?? const {};
  Set<String> get roles => _user?.roles ?? const {};

  bool can(String permission) => _user?.can(permission) ?? false;

  bool canAny(Iterable<String> required) => _user?.canAny(required) ?? false;

  bool hasRole(String role) => _user?.hasRole(role) ?? false;

  // -------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------

  /// Restores a stored session at launch (§4).
  ///
  /// Verifies with the server rather than trusting what is on disk: the
  /// account may have been disabled or its sessions revoked since the app was
  /// last open, and the stored token would say nothing about it.
  Future<void> restore() async {
    await api.restore();
    if (api.tokens == null) {
      _set(AuthStatus.signedOut);
      return;
    }

    try {
      _user = await api.me();
      _set(AuthStatus.signedIn);
    } on AuthApiException catch (error) {
      if (error.isNetworkError) {
        // Offline at launch is not "signed out". The tokens are kept and the
        // next successful call will settle it; until then the user stays out
        // of the app rather than being silently signed in with stale
        // permissions.
        _endedReason =
            'Could not reach the server to confirm your session. '
            'Check your connection and sign in again.';
      }
      await api.forget();
      _set(AuthStatus.signedOut);
    }
  }

  Future<void> signIn({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    _busy = true;
    _endedReason = null;
    notifyListeners();

    try {
      _user = await api.login(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );
      _busy = false;
      _set(AuthStatus.signedIn);
    } catch (_) {
      _busy = false;
      notifyListeners();
      // Rethrown so the form can show the specific message; the controller
      // only owns the state, not the presentation of the failure.
      rethrow;
    }
  }

  Future<void> signOut() async {
    _busy = true;
    notifyListeners();

    await api.logout();
    _user = null;
    _busy = false;
    _endedReason = null;
    pendingRedirect = null;
    _set(AuthStatus.signedOut);
  }

  /// Ends every other session, or all of them including this one (§18).
  Future<int> signOutEverywhere({bool keepCurrent = true}) async {
    final revoked = await api.logoutEverywhere(keepCurrent: keepCurrent);
    if (!keepCurrent) {
      _user = null;
      _set(AuthStatus.signedOut);
    }
    return revoked;
  }

  /// Re-reads the user, after something that changes their permissions or
  /// profile.
  Future<void> refreshUser() async {
    if (!isAuthenticated) return;
    try {
      _user = await api.me();
      notifyListeners();
    } on AuthApiException catch (error) {
      if (error.isAuthExpired) _onSessionLost();
    }
  }

  /// Applies a profile change already persisted by the API, without a second
  /// round trip.
  void applyProfile(AuthUser updated) {
    // The API's profile response has no session id or permissions on it, so
    // the fields that came from the session are carried across rather than
    // being blanked.
    _user = _user?.copyWith(
      name: updated.name,
      phone: updated.phone,
      email: updated.email,
      emailVerified: updated.emailVerified,
    );
    notifyListeners();
  }

  /// Changes the password and keeps this device signed in (§10).
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await api.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    // The server issued a replacement pair for this device; everything else
    // was signed out.
    await refreshUser();
  }

  void _onSessionLost() {
    if (_status == AuthStatus.signedOut) return;
    _user = null;
    _endedReason = 'Your session has expired. Please sign in again.';
    _set(AuthStatus.signedOut);
  }

  /// Clears the "why am I here" note once the sign-in screen has shown it.
  void acknowledgeEndedReason() {
    if (_endedReason == null) return;
    _endedReason = null;
    notifyListeners();
  }

  void _set(AuthStatus next) {
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    api.onSessionLost = null;
    api.dispose();
    super.dispose();
  }
}

/// Builds the controller the app runs with.
///
/// Kept out of `main.dart` so tests can construct the same object against a
/// fake transport.
AuthController buildAuthController({String? baseUrl, TokenStorage? storage}) {
  return AuthController(
    api: AuthApi(
      baseUrl: baseUrl ?? AuthApi.defaultBaseUrl,
      storage: storage ?? SecureTokenStorage(),
    ),
  );
}
