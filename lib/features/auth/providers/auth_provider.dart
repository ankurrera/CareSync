import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/biometric_service.dart';
import '../../../services/secure_storage_service.dart';
import '../../../services/supabase_service.dart';
import '../../shared/models/user_profile.dart';

/// Provider for auth state changes
final authStateProvider = StreamProvider<User?>((ref) {
  return SupabaseService.instance.authStateChanges.map((state) => state.session?.user);
});

/// Provider for current user profile
final currentProfileProvider = FutureProvider<UserProfile?>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return null;

  final profileData = await SupabaseService.instance.getProfile();
  if (profileData == null) return null;

  return UserProfile.fromJson(profileData);
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
final biometricEnabledProvider = FutureProvider<bool>((ref) async {
  return await SecureStorageService.instance.isBiometricEnabled();
});

/// Auth notifier for handling authentication operations
class AuthNotifier extends StateNotifier<AsyncValue<User?>> {
  AuthNotifier() : super(const AsyncValue.loading()) {
    _init();
  }

  final _supabase = SupabaseService.instance;
  final _biometric = BiometricService.instance;
  final _storage = SecureStorageService.instance;

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
      // Create auth user
      final response = await _supabase.signUp(
        email: email,
        password: password,
      );

      if (response.user == null) {
        throw Exception('Failed to create account');
      }

      // Create profile
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

  /// Sign in with email and password
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    state = const AsyncValue.loading();
    try {
      final response = await _supabase.signIn(
        email: email,
        password: password,
      );

      if (response.user == null) {
        throw Exception('Invalid credentials');
      }

      // Store user ID
      await _storage.setUserId(response.user!.id);

      state = AsyncValue.data(response.user);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      rethrow;
    }
  }

  /// Sign in with biometrics (for returning users on enrolled devices)
  Future<bool> signInWithBiometric() async {
    try {
      // Check if biometric is enabled
      final isEnabled = await _storage.isBiometricEnabled();
      if (!isEnabled) return false;

      // Verify biometric
      final authenticated = await _biometric.authenticate(
        reason: 'Authenticate to sign in to CareSync',
      );

      if (!authenticated) return false;

      // Update device last used
      final deviceId = await _storage.getDeviceId();
      if (deviceId != null) {
        await _supabase.updateDeviceLastUsed(deviceId);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Enroll biometrics for this device
  Future<void> enrollBiometric() async {
    try {
      // First verify biometric works
      final authenticated = await _biometric.authenticate(
        reason: 'Set up biometric login for CareSync',
      );

      if (!authenticated) {
        throw Exception('Biometric authentication failed');
      }

      // Get or create device ID
      final deviceId = await _storage.getOrCreateDeviceId();

      // Get device name
      final deviceName = await _getDeviceName();

      // Register device in backend
      await _supabase.registerDevice(
        deviceId: deviceId,
        deviceName: deviceName,
        platform: Platform.isIOS ? 'ios' : 'android',
      );

      // Enable biometric locally
      await _storage.setBiometricEnabled(true);
    } catch (e) {
      rethrow;
    }
  }

  /// Sign out
  Future<void> signOut() async {
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
}

final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<User?>>((ref) {
  return AuthNotifier();
});

