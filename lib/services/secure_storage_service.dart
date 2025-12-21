import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Service for securely storing sensitive data on the device
class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const _uuid = Uuid();

  // Storage keys
  static const String _deviceIdKey = 'caresync_device_id';
  static const String _userIdKey = 'caresync_user_id';
  static const String _biometricEnabledKey = 'caresync_biometric_enabled';
  static const String _refreshTokenKey = 'caresync_refresh_token';

  // ─────────────────────────────────────────────────────────────────────────
  // DEVICE ID (Biometric Binding)
  // ─────────────────────────────────────────────────────────────────────────

  /// Get or create a unique device ID for biometric binding
  /// This ID is generated once per device and stored securely
  Future<String> getOrCreateDeviceId() async {
    String? deviceId = await _storage.read(key: _deviceIdKey);
    if (deviceId == null) {
      deviceId = _uuid.v4();
      await _storage.write(key: _deviceIdKey, value: deviceId);
    }
    return deviceId;
  }

  /// Get the stored device ID (returns null if not set)
  Future<String?> getDeviceId() async {
    return await _storage.read(key: _deviceIdKey);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // USER SESSION
  // ─────────────────────────────────────────────────────────────────────────

  /// Store the current user ID for quick access
  Future<void> setUserId(String userId) async {
    await _storage.write(key: _userIdKey, value: userId);
  }

  /// Get the stored user ID
  Future<String?> getUserId() async {
    return await _storage.read(key: _userIdKey);
  }

  /// Store refresh token for session persistence
  Future<void> setRefreshToken(String token) async {
    await _storage.write(key: _refreshTokenKey, value: token);
  }

  /// Get stored refresh token
  Future<String?> getRefreshToken() async {
    return await _storage.read(key: _refreshTokenKey);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BIOMETRIC SETTINGS
  // ─────────────────────────────────────────────────────────────────────────

  /// Check if biometric login is enabled for this device
  Future<bool> isBiometricEnabled() async {
    final value = await _storage.read(key: _biometricEnabledKey);
    return value == 'true';
  }

  /// Enable or disable biometric login for this device
  Future<void> setBiometricEnabled(bool enabled) async {
    await _storage.write(
      key: _biometricEnabledKey,
      value: enabled.toString(),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CLEAR DATA
  // ─────────────────────────────────────────────────────────────────────────

  /// Clear all stored data (on logout)
  Future<void> clearAll() async {
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _biometricEnabledKey);
    await _storage.delete(key: _refreshTokenKey);
    // Note: We don't delete deviceId - it persists across logins
  }

  /// Clear only session data (keeps device ID)
  Future<void> clearSession() async {
    await _storage.delete(key: _userIdKey);
    await _storage.delete(key: _refreshTokenKey);
  }
}

