package com.coldwallet.vault

internal enum class DeviceAuthMode {
    StrongOrCredential,
    CredentialOnly,
    Api29CredentialAllowed,
    Api28BiometricOnly,
    RejectNotSecure,
    RejectUnavailable,
}

internal fun selectDeviceAuthMode(
    sdkInt: Int,
    deviceSecure: Boolean,
    strongBiometricStatus: Int?,
    deviceCredentialStatus: Int?,
): DeviceAuthMode {
    if (!deviceSecure) return DeviceAuthMode.RejectNotSecure
    if (sdkInt < 28) return DeviceAuthMode.RejectUnavailable
    if (sdkInt < 29) return DeviceAuthMode.Api28BiometricOnly
    if (sdkInt < 30) return DeviceAuthMode.Api29CredentialAllowed
    if (strongBiometricStatus == 0) return DeviceAuthMode.StrongOrCredential
    if (deviceCredentialStatus == 0) return DeviceAuthMode.CredentialOnly
    return DeviceAuthMode.RejectUnavailable
}

internal data class AuthChannelError(val code: String, val message: String)

// BiometricPrompt error codes. Kept numeric so the classifier stays free of Android types.
internal const val BIOMETRIC_ERROR_USER_CANCELED = 10
internal const val BIOMETRIC_ERROR_NEGATIVE_BUTTON = 13

internal fun classifyBiometricCancellation(errorCode: Int, userLeaving: Boolean): AuthChannelError {
    if (userLeaving) {
        return AuthChannelError("backgrounded", "應用程式已離開前景，請重新驗證")
    }
    if (errorCode == BIOMETRIC_ERROR_USER_CANCELED || errorCode == BIOMETRIC_ERROR_NEGATIVE_BUTTON) {
        return AuthChannelError("cancelled", "已取消裝置驗證")
    }
    return AuthChannelError("authentication_failed", "裝置驗證未完成，金庫仍鎖定")
}
