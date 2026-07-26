import 'package:local_auth/local_auth.dart';

class BiometricAuthResult {
  final bool success;
  final String? errorMessage;
  const BiometricAuthResult({required this.success, this.errorMessage});
}

/// Gate that must pass before the app is allowed to unwrap the VEK using
/// the device's local key. Biometrics never touch the VEK directly — they
/// only decide whether [VaultRepository.unlock] is permitted to proceed.
class BiometricAuthService {
  BiometricAuthService._();
  static final BiometricAuthService instance = BiometricAuthService._();

  final LocalAuthentication _localAuth = LocalAuthentication();

  Future<bool> isAvailable() async {
    final canCheck = await _localAuth.canCheckBiometrics;
    final isSupported = await _localAuth.isDeviceSupported();
    return canCheck || isSupported;
  }

  Future<BiometricAuthResult> authenticate({String reason = 'Unlock your PeerVault'}) async {
    try {
      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // allow PIN/pattern/passcode fallback (device credential)
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      return BiometricAuthResult(success: didAuthenticate);
    } catch (e) {
      return BiometricAuthResult(success: false, errorMessage: e.toString());
    }
  }
}
