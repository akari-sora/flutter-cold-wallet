import 'dart:ffi';
import 'dart:io';

/// Cross-platform dynamic library loader for Rust C-ABI artifacts.
class NativeLibraryLoader {
  static DynamicLibrary loadWalletLib() {
    if (Platform.isWindows) {
      final envPath = Platform.environment['WALLET_FFI_PATH'];
      if (envPath != null && File(envPath).existsSync()) {
        return DynamicLibrary.open(envPath);
      }
      final relativeCandidates = [
        'target/release/wallet_ffi.dll',
        '../../target/release/wallet_ffi.dll',
        '../../../target/release/wallet_ffi.dll',
        'target/debug/wallet_ffi.dll',
        '../../target/debug/wallet_ffi.dll',
        '../../../target/debug/wallet_ffi.dll',
        'wallet_ffi.dll',
      ];
      for (final p in relativeCandidates) {
        if (File(p).existsSync()) {
          return DynamicLibrary.open(File(p).absolute.path);
        }
      }
      return DynamicLibrary.open('wallet_ffi.dll');
    } else if (Platform.isAndroid) {
      return DynamicLibrary.open('libwallet_ffi.so');
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else if (Platform.isMacOS || Platform.isLinux) {
      // Host test runs point at a locally built library; app bundles link it in.
      final envPath = Platform.environment['WALLET_FFI_PATH'];
      if (envPath != null && File(envPath).existsSync()) {
        return DynamicLibrary.open(envPath);
      }
      return Platform.isMacOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open('libwallet_ffi.so');
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  static DynamicLibrary loadVaultLib() {
    if (Platform.isWindows) {
      final envPath = Platform.environment['VAULT_FFI_PATH'];
      if (envPath != null && File(envPath).existsSync()) {
        return DynamicLibrary.open(envPath);
      }
      final relativeCandidates = [
        'target/release/vault_ffi.dll',
        '../../target/release/vault_ffi.dll',
        '../../../target/release/vault_ffi.dll',
        'target/debug/vault_ffi.dll',
        '../../target/debug/vault_ffi.dll',
        '../../../target/debug/vault_ffi.dll',
        'vault_ffi.dll',
      ];
      for (final p in relativeCandidates) {
        if (File(p).existsSync()) {
          return DynamicLibrary.open(File(p).absolute.path);
        }
      }
      return DynamicLibrary.open('vault_ffi.dll');
    } else if (Platform.isAndroid) {
      return DynamicLibrary.open('libvault_ffi.so');
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else if (Platform.isMacOS || Platform.isLinux) {
      // Host test runs point at a locally built library; app bundles link it in.
      final envPath = Platform.environment['VAULT_FFI_PATH'];
      if (envPath != null && File(envPath).existsSync()) {
        return DynamicLibrary.open(envPath);
      }
      return Platform.isMacOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open('libvault_ffi.so');
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }
}
