# Android build notes

Candidate version: 1.2.1+10. Build dependencies: Flutter 3.41.3, Dart 3.11.1, Rust 1.96.1, cargo-ndk 4.1.2, JDK 17, Android NDK 27.0.12077973.

Generate each app’s ARM64 and x86_64 FFI libraries with `cargo ndk`, run `flutter pub get`, then build the Android app bundle with Flutter build name 1.2.1 and build number 10. The candidate APK was derived from its AAB with bundletool. Release keys and credentials are not included. The Gradle wrapper distribution checksum and Rust toolchain are not pinned in source; bit-identical binary reconstruction is not asserted.
