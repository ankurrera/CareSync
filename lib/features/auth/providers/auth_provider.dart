import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/biometric_service.dart';
import '../../../services/secure_storage_service.dart';
import '../../../services/supabase_service.dart';
import '../../../services/kyc_service.dart';
import '../../../services/two_factor_service.dart';
import '../../../services/device_service.dart';
import '../../../services/audit_service.dart';
import '../../../services/auth_controller.dart';
import '../../patient/providers/patient_provider.dart';
import '../../shared/models/user_profile.dart';

/// Provider for auth state changes
final authStateProvider = StreamProvider<User?>((ref) {
  return SupabaseService.instance.authStateChanges.map((state) => state.session?.user);
});

/// Provider for current user profile - auto-refreshes on auth changes
final currentProfileProvider = FutureProvider<UserProfile?>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return null;

  final profileData = await SupabaseService.instance.getProfile();
  if (profileData == null) return null;

  return UserProfile.fromJson(profileData);
});

/// Provider to invalidate all user data on sign out
final signOutProvider = Provider<Future<void> Function(WidgetRef ref)>((ref) {
  return (WidgetRef widgetRef) async {
    await ref.read(authNotifierProvider.notifier).signOut();
    // Invalidate all user-related providers
    widgetRef.invalidate(currentProfileProvider);
    widgetRef.invalidate(biometricEnabledProvider);
    widgetRef.invalidate(patientDataProvider);
    widgetRef.invalidate(patientPrescriptionsProvider);
    widgetRef.invalidate(medicalConditionsProvider);
  };
});

/// Provider for biometric availability
final biometricAvailableProvider = FutureProvider<bool>((ref) async {
  return await BiometricService.instance.isBiometricAvailable();
});

/// Provider for biometric type name
final biometricTypeNameProvider = FutureProvider<String>((ref) async {
  return await BiometricService.instance.getBiometricTypeName();
});

/// Provider for checking if biometric is enabled on this device
/// Uses SSOT (Single Source of Truth) - checks both backend and local storage
final biometricEnabledProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) {
    print('[BIO] No user session - biometric not enabled');
    return false;
  }
  
  // Use AuthController's SSOT method
  final authController = AuthController.instance;
  final isEnabled = await authController.isBiometricAlreadyEnabled(user.id);
  
  print('[BIO] Provider check result: isEnabled = $isEnabled');
  return isEnabled;
});

/// Provider for KYC status
final kycStatusProvider = FutureProvider<KYCVerification?>((ref) async {
  return await KYCService.instance.getKYCStatus();
});

/// Provider for user devices
final userDevicesProvider = FutureProvider<List<RegisteredDevice>>((ref) async {
  return await DeviceService.instance.getUserDevices();
});

/// Provider for current device registration status
final currentDeviceRegisteredProvider = FutureProvider<bool>((ref) async {
  return await DeviceService.instance.isDeviceRegistered();
});

/// Auth notifier for handling authentication operations
class AuthNotifier extends StateNotifier<AsyncValue<User?>> {
  AuthNotifier() : super(const AsyncValue.loading()) {
    _init();
  }

  final _supabase = SupabaseService.instance;
  final _biometric = BiometricService.instance;
  final _storage = SecureStorageService.instance;
  final _kycService = KYCService.instance;
  final _twoFactorService = TwoFactorService.instance;
  final _deviceService = DeviceService.instance;
  final _auditService = AuditService.instance;
  final _authController = AuthController.instance;

  void _init() {
    state = AsyncValue.data(_supabase.currentUser);
  }

  /// Sign up with email and password
  Future<void> signUp({
    required String email,
    required String password,
    required String fullName,
    required String phone,
    required String role,
  }) async {
    state = const AsyncValue.loading();
    try {
      // Create auth user with metadata (triggers profile creation)
      final response = await _supabase.signUp(
        email: email,
        password: password,
        data: {
          'full_name': fullName,
          'phone': phone,
          'role': role,
        },
      );

      if (response.user == null) {
        throw Exception('Failed to create account');
      }

      // Update profile to ensure phone is saved (trigger might not include it)
      await _supabase.upsertProfile({
        'email': email,
        'phone': phone,
        'full_name': fullName,
        'role': role,
      });

      // Create role-specific record
      await _createRoleRecord(role);

      // Store user ID
      await _storage.setUserId(response.user!.id);

      state = AsyncValue.data(response.user);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      rethrow;
    }
  }

  /// Sign in with email and password (includes 2FA check)
  Future<SignInResult> signIn({
    required String email,
    required String password,
  }) async {
    state = const AsyncValue.loading();
    try {
      print('[AUTH] Sign in attempt for: $email');
      
      final response = await _supabase.signIn(
        email: email,
        password: password,
      );

      if (response.user == null) {
        throw Exception('Invalid credentials');
      }

      print('[AUTH] Login success');
      final userId = response.user!.id;

      // Store tokens for session persistence
      if (response.session != null) {
        await _storage.setAccessToken(response.session!.accessToken);
        await _storage.setRefreshToken(response.session!.refreshToken ?? '');
      }

      // Store user ID
      await _storage.setUserId(userId);

      // Check if device is registered
      final isDeviceRegistered = await _deviceService.isDeviceRegistered();

      // If device is not registered, require 2FA
      if (!isDeviceRegistered) {
        state = AsyncValue.data(response.user);
        return SignInResult(
          user: response.user,
          requiresTwoFactor: true,
          requiresKyc: false,
          requiresBiometric: false,
          email: email,
        );
      }

      // Device is registered - now check KYC and biometric requirements
      print('[AUTH] Checking KYC status');
      final kycVerified = await _kycService.isKYCVerified(userId);
      
      if (!kycVerified) {
        print('[AUTH] KYC not verified');
        state = AsyncValue.data(response.user);
        return SignInResult(
          user: response.user,
          requiresTwoFactor: false,
          requiresKyc: true,
          requiresBiometric: false,
        );
      }

      print('[AUTH] KYC verified');

      // Check device biometric binding
      final deviceId = await _storage.getDeviceId();
      if (deviceId != null) {
        final device = await _supabase.client
            .from('registered_devices')
            .select()
            .eq('user_id', userId)
            .eq('device_id', deviceId)
            .maybeSingle();

        // Check if device is revoked
        if (device != null && device['revoked'] == true) {
          print('[AUTH] Device revoked');
          await _storage.clearSession();
          throw Exception('Device has been revoked');
        }

        // Check if biometric needs to be enabled using helper
        if (_needsBiometricSetup(device)) {
          print('[AUTH] Biometric required');
          state = AsyncValue.data(response.user);
          return SignInResult(
            user: response.user,
            requiresTwoFactor: false,
            requiresKyc: false,
            requiresBiometric: true,
          );
        }

        print('[AUTH] Device trusted');
      }

      // Update device last used
      await _deviceService.updateDeviceLastUsed();

      // Log login
      if (deviceId != null) {
        await _auditService.logLogin(deviceId: deviceId);
      }

      state = AsyncValue.data(response.user);
      return SignInResult(
        user: response.user,
        requiresTwoFactor: false,
        requiresKyc: false,
        requiresBiometric: false,
      );
    } on AuthException catch (e, st) {
      // Map Supabase auth errors to friendlier messages
      final message = _mapAuthError(e);
      state = AsyncValue.error(message, st);
      throw Exception(message);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      throw Exception('Unable to sign in. Please try again.');
    }
  }

  /// Complete 2FA and register device
  Future<void> completeTwoFactor({
    required bool registerDevice,
    required bool enableBiometric,
  }) async {
    try {
      if (registerDevice) {
        // Register device
        await _deviceService.registerDevice(
          biometricEnabled: enableBiometric,
        );

        // Log device registration
        final deviceInfo = await _deviceService.getDeviceInfo();
        await _auditService.logDeviceRegistration(
          deviceId: deviceInfo.deviceId,
          deviceName: deviceInfo.deviceName,
        );

        // Enable biometric locally if requested
        if (enableBiometric) {
          await _storage.setBiometricEnabled(true);
        }
      }

      // Update last activity
      await _storage.updateLastActivity();
    } catch (e) {
      rethrow;
    }
  }

  /// Sign in with biometrics (for returning users on enrolled devices)
  Future<bool> signInWithBiometric() async {
    try {
      // Check if session has timed out
      final hasTimedOut = await _storage.hasSessionTimedOut();
      if (hasTimedOut) {
        return false;
      }

      // Check if biometric is enabled
      final isEnabled = await _storage.isBiometricEnabled();
      if (!isEnabled) return false;

      // Verify biometric
      final authenticated = await _biometric.authenticate(
        reason: 'Authenticate to sign in to CareSync',
      );

      if (!authenticated) return false;

      // Try to restore session from stored tokens
      final accessToken = await _storage.getAccessToken();
      final refreshToken = await _storage.getRefreshToken();

      if (accessToken != null && refreshToken != null) {
        try {
          // Use recoverSession with both tokens
          final response = await _supabase.auth.recoverSession(refreshToken);
          if (response.session == null) {
            return false;
          }
        } catch (e) {
          // Token expired or invalid
          return false;
        }
      }

      // Update device last used
      final deviceId = await _storage.getDeviceId();
      if (deviceId != null) {
        await _deviceService.updateDeviceLastUsed();
        await _auditService.logLogin(deviceId: deviceId, biometric: true);
      }

      // Update last activity
      await _storage.updateLastActivity();

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Enroll biometrics for this device
  Future<void> enrollBiometric() async {
    try {
      await _authController.forceEnableBiometric();
      
      // Log device registration
      final deviceInfo = await _deviceService.getDeviceInfo();
      await _auditService.logDeviceRegistration(
        deviceId: deviceInfo.deviceId,
        deviceName: deviceInfo.deviceName,
      );
    } catch (e) {
      rethrow;
    }
  }

  /// Helper to determine if biometric setup is needed per spec
  bool _needsBiometricSetup(Map<String, dynamic>? device) {
    if (device == null) return true;
    // Note: revoked devices are handled earlier in the authentication flow
    if (device['biometric_enabled'] != true) return true;
    return false;
  }

  /// Sign out
  Future<void> signOut() async {
    // Log logout
    final deviceId = await _storage.getDeviceId();
    if (deviceId != null) {
      await _auditService.logLogout(deviceId: deviceId);
    }

    await _supabase.signOut();
    await _storage.clearSession();
    state = const AsyncValue.data(null);
  }

  /// Create role-specific record after signup
  Future<void> _createRoleRecord(String role) async {
    switch (role) {
      case 'patient':
        await _supabase.upsertPatientData({
          'qr_code_id': DateTime.now().millisecondsSinceEpoch.toString(),
        });
        break;
      case 'doctor':
        await _supabase.client.from('doctors').upsert({
          'user_id': _supabase.currentUserId,
        });
        break;
      case 'pharmacist':
        await _supabase.client.from('pharmacists').upsert({
          'user_id': _supabase.currentUserId,
        });
        break;
      case 'first_responder':
        await _supabase.client.from('first_responders').upsert({
          'user_id': _supabase.currentUserId,
        });
        break;
    }
  }

  Future<String> _getDeviceName() async {
    // Simplified device name - in production, use device_info_plus
    if (Platform.isIOS) {
      return 'iPhone';
    } else if (Platform.isAndroid) {
      return 'Android Device';
    }
    return 'Unknown Device';
  }

  String _mapAuthError(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('invalid login credentials')) {
      return 'Incorrect email or password';
    }
    if (msg.contains('email not confirmed')) {
      return 'Please verify your email before signing in';
    }
    if (msg.contains('user not found')) {
      return 'No account found for this email';
    }
    return 'Unable to sign in. Please try again.';
  }
}

/// Result of sign in operation
class SignInResult {
  final User? user;
  final bool requiresTwoFactor;
  final bool requiresKyc;
  final bool requiresBiometric;
  final String? email;

  SignInResult({
    this.user,
    required this.requiresTwoFactor,
    required this.requiresKyc,
    required this.requiresBiometric,
    this.email,
  });
}

final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<User?>>((ref) {
  return AuthNotifier();
});

