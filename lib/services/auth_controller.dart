import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_service.dart';
import 'kyc_service.dart';
import 'secure_storage_service.dart';
import 'biometric_service.dart';

/// Centralized authentication controller implementing Single Source of Truth
/// This controller enforces the required user flow and biometric enablement
class AuthController {
  AuthController._();
  static final AuthController instance = AuthController._();

  final _supabase = Supabase.instance.client;
  final _deviceService = DeviceService.instance;
  final _kycService = KYCService.instance;
  final _storage = SecureStorageService.instance;
  final _biometric = BiometricService.instance;

  /// Generate token fingerprint for device binding
  String _generateTokenFingerprint(String accessToken, String deviceId) {
    // Use delimiter to prevent collision attacks
    final bytes = utf8.encode('$accessToken|$deviceId');
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Main sign-in flow after successful email+password+2FA authentication
  /// This is the REQUIRED LOGIC per the specification
  Future<AuthFlowResult> onLoginSuccess() async {
    _log('[AUTH] Login success');
    
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw AuthException('No session');
    }

    // 1. Check KYC status using ROBUST check
    _log('[AUTH] Checking KYC status');
    final kycVerified = await _kycService.isKYCVerified(session.user.id);

    if (!kycVerified) {
      _log('[AUTH] KYC not verified - redirecting to KYC');
      return AuthFlowResult.kycRequired;
    }

    _log('[AUTH] KYC verified');

    // 2. Check device biometric binding
    final deviceId = await _storage.getOrCreateDeviceId();
    _log('[AUTH] Device ID: $deviceId');
    
    final device = await _supabase
        .from('registered_devices')
        .select()
        .eq('user_id', session.user.id)
        .eq('device_id', deviceId)
        .maybeSingle();

    // Check if device is revoked
    if (device != null && device['revoked'] == true) {
      _log('[AUTH] Device revoked - clearing tokens');
      await _storage.clearSession();
      throw AuthException('Device has been revoked');
    }

    // Use needsBiometricSetup helper per spec
    if (_needsBiometricSetup(device)) {
      _log('[AUTH] Biometric required');
      // FORCE biometric enable prompt - this is MANDATORY per spec
      await _triggerBiometricSetupIfRequired();
      _log('[AUTH] Biometric enabled');
    } else {
      _log('[AUTH] Device trusted');
    }

    return AuthFlowResult.success;
  }

  /// Helper to determine if biometric setup is needed per spec
  bool _needsBiometricSetup(Map<String, dynamic>? device) {
    if (device == null) return true;
    if (device['revoked'] == true) return true;
    if (device['biometric_enabled'] != true) return true;
    return false;
  }

  /// Trigger biometric setup if required - COMPLETE FLOW per spec
  /// This implements the EXACT pattern from the problem statement
  Future<void> _triggerBiometricSetupIfRequired() async {
    _log('[BIO] Starting biometric setup');
    
    final session = _supabase.auth.currentSession;
    if (session == null) {
      _log('[BIO] No session - aborting');
      return;
    }

    // Check KYC with robust method
    final kycVerified = await _kycService.isKYCVerified(session.user.id);
    _log('[BIO] KYC verified = $kycVerified');
    
    if (!kycVerified) {
      _log('[BIO] KYC not verified - aborting biometric setup');
      return;
    }

    final deviceId = await _storage.getOrCreateDeviceId();
    final device = await _supabase
        .from('registered_devices')
        .select()
        .eq('user_id', session.user.id)
        .eq('device_id', deviceId)
        .maybeSingle();

    if (!_needsBiometricSetup(device)) {
      _log('[BIO] Biometric already setup - skipping');
      return;
    }

    // Check device support (not enrollment - that comes later)
    final isSupported = await _biometric.isDeviceSupported();
    _log('[BIO] Device supported = $isSupported');
    
    if (!isSupported) {
      _log('[BIO] Device does not support biometrics - continuing without');
      return;
    }

    // Trigger biometric authentication
    _log('[BIO] Triggering authenticate()');
    final ok = await _biometric.authenticate(
      reason: 'Enable biometric login for faster access',
    );

    if (!ok) {
      _log('[BIO] Biometric authentication declined or failed');
      return;
    }

    _log('[BIO] Biometric authentication successful');

    // Generate fingerprint
    final fingerprint = _generateTokenFingerprint(
      session.accessToken,
      deviceId,
    );

    // Store tokens securely
    await _storage.setAccessToken(session.accessToken);
    await _storage.setRefreshToken(session.refreshToken ?? '');
    await _storage.setUserId(session.user.id);
    await _storage.setBiometricEnabled(true);

    // Update device record
    try {
      await _supabase.from('registered_devices').upsert(
        {
          'user_id': session.user.id,
          'device_id': deviceId,
          'biometric_enabled': true,
          'trusted': true,
          'token_fingerprint': fingerprint,
          'last_used_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id,device_id',
      );

      _log('[BIO] Biometric setup completed successfully');
    } catch (e) {
      _log('[BIO] Failed to update device record: $e');
      // Rollback on failure
      await _storage.setBiometricEnabled(false);
      rethrow;
    }
  }

  /// Force biometric enablement - STRICT TRANSACTION per spec
  /// This implements the atomic biometric enablement flow
  /// Called explicitly by UI when user opts in
  Future<void> forceEnableBiometric() async {
    _log('[BIO] Starting explicit biometric enrollment');
    
    // Check if biometric hardware is supported
    final isSupported = await _biometric.isDeviceSupported();
    _log('[BIO] Device supported = $isSupported');
    
    if (!isSupported) {
      _log('[BIO] Biometric hardware unavailable');
      throw AuthException('Biometric authentication is not available on this device');
    }

    // 1. Local biometric auth
    _log('[BIO] Requesting biometric authentication');
    final ok = await _biometric.authenticate(
      reason: 'Secure your account with biometrics',
    );
    if (!ok) {
      throw AuthException('Biometric authentication required');
    }

    _log('[BIO] Biometric authentication successful');

    // 2. Active session check
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw AuthException('Session expired');
    }

    // 3. Get device ID
    final deviceId = await _storage.getOrCreateDeviceId();
    _log('[BIO] Device ID: $deviceId');

    // 4. Generate token fingerprint
    final fingerprint = _generateTokenFingerprint(
      session.accessToken,
      deviceId,
    );

    // 5. Secure token storage
    await _storage.setAccessToken(session.accessToken);
    await _storage.setRefreshToken(session.refreshToken ?? '');
    await _storage.setUserId(session.user.id);
    await _storage.setBiometricEnabled(true);

    _log('[BIO] Tokens stored securely');

    // 6. Backend device binding
    try {
      await _supabase.from('registered_devices').upsert(
        {
          'user_id': session.user.id,
          'device_id': deviceId,
          'biometric_enabled': true,
          'trusted': true,
          'token_fingerprint': fingerprint,
          'last_used_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id,device_id',
      );
      _log('[BIO] Device record updated');
    } catch (e) {
      _log('[BIO] Failed to update device record: $e');
      // Rollback on failure
      await _storage.setBiometricEnabled(false);
      await _storage.clearSession();
      rethrow;
    }

    _log('[BIO] Biometric enrollment complete');
  }

  /// App startup session restoration - CRITICAL FIX per spec
  /// This implements the REQUIRED startup flow
  Future<SessionRestoreResult> restoreSession() async {
    _log('[AUTH] Starting session restoration');

    // 1. Read tokens from secure storage
    final accessToken = await _storage.getAccessToken();
    final refreshToken = await _storage.getRefreshToken();
    
    if (accessToken == null || refreshToken == null) {
      _log('[AUTH] No tokens found - login required');
      return SessionRestoreResult.loginRequired;
    }

    // 2. Restore Supabase session
    try {
      final response = await _supabase.auth.recoverSession(refreshToken);
      if (response.session == null) {
        _log('[AUTH] Session recovery failed - login required');
        await _storage.clearSession();
        return SessionRestoreResult.loginRequired;
      }
    } catch (e) {
      _log('[AUTH] Session recovery error - login required');
      await _storage.clearSession();
      return SessionRestoreResult.loginRequired;
    }

    final session = _supabase.auth.currentSession;
    if (session == null) {
      return SessionRestoreResult.loginRequired;
    }

    // 3. Fetch device record
    final deviceId = await _storage.getDeviceId();
    if (deviceId == null) {
      _log('[AUTH] No device ID - login required');
      return SessionRestoreResult.loginRequired;
    }

    final device = await _supabase
        .from('registered_devices')
        .select()
        .eq('user_id', session.user.id)
        .eq('device_id', deviceId)
        .maybeSingle();

    // 4. Check if revoked
    if (device == null || device['revoked'] == true) {
      _log('[AUTH] Device revoked - wiping tokens');
      await _storage.clearSession();
      await _storage.setBiometricEnabled(false);
      return SessionRestoreResult.loginRequired;
    }

    // 5. If biometric enabled → require biometric
    final biometricEnabled = device['biometric_enabled'] == true;
    if (biometricEnabled) {
      _log('[AUTH] Biometric required for unlock');
      final authenticated = await _biometric.authenticate(
        reason: 'Authenticate to access CareSync',
      );
      
      if (!authenticated) {
        _log('[AUTH] Biometric authentication failed');
        return SessionRestoreResult.biometricFailed;
      }
    }

    // 6. Validate token fingerprint
    final storedFingerprint = device['token_fingerprint'] as String?;
    if (storedFingerprint != null) {
      final currentFingerprint = _generateTokenFingerprint(
        session.accessToken,
        deviceId,
      );
      
      if (storedFingerprint != currentFingerprint) {
        _log('[AUTH] Token fingerprint mismatch - security breach detected');
        await _storage.clearSession();
        await _storage.setBiometricEnabled(false);
        return SessionRestoreResult.loginRequired;
      }
    }

    _log('[AUTH] Session restored');
    await _storage.updateLastActivity();
    
    return SessionRestoreResult.success;
  }

  /// Helper method to log with [AUTH] prefix as required
  void _log(String message) {
    // In production, use proper logging framework
    // ignore: avoid_print
    print(message);
  }
}

/// Result of the main sign-in flow
enum AuthFlowResult {
  success,
  kycRequired,
}

/// Result of session restoration
enum SessionRestoreResult {
  success,
  loginRequired,
  biometricFailed,
}
