package com.coldwallet.vault

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceAuthPolicyTest {
    @Test
    fun rejectNotSecureRegardlessOfSdkOrStatuses() {
        for (sdk in listOf(28, 29, 30, 36)) {
            assertEquals(
                DeviceAuthMode.RejectNotSecure,
                selectDeviceAuthMode(sdk, deviceSecure = false, 0, 0),
            )
        }
    }

    @Test
    fun sdk27SecureRejectUnavailable() {
        assertEquals(
            DeviceAuthMode.RejectUnavailable,
            selectDeviceAuthMode(27, deviceSecure = true, null, null),
        )
    }

    @Test
    fun sdk28SecureApi28BiometricOnly() {
        assertEquals(
            DeviceAuthMode.Api28BiometricOnly,
            selectDeviceAuthMode(28, deviceSecure = true, null, null),
        )
    }

    @Test
    fun sdk29SecureApi29CredentialAllowed() {
        assertEquals(
            DeviceAuthMode.Api29CredentialAllowed,
            selectDeviceAuthMode(29, deviceSecure = true, null, null),
        )
    }

    @Test
    fun sdk30And36StrongSuccessUsesStrongOrCredential() {
        for (sdk in listOf(30, 36)) {
            for (credential in listOf(0, 11, null)) {
                assertEquals(
                    DeviceAuthMode.StrongOrCredential,
                    selectDeviceAuthMode(sdk, deviceSecure = true, strongBiometricStatus = 0, credential),
                )
            }
        }
    }

    @Test
    fun sdk30And36CredentialOnlyWhenStrongNotSuccess() {
        for (sdk in listOf(30, 36)) {
            for (strong in listOf(11, null)) {
                assertEquals(
                    DeviceAuthMode.CredentialOnly,
                    selectDeviceAuthMode(sdk, deviceSecure = true, strong, deviceCredentialStatus = 0),
                )
            }
        }
    }

    @Test
    fun sdk30RejectUnavailableWhenNeitherAuthenticatorSucceeds() {
        assertEquals(
            DeviceAuthMode.RejectUnavailable,
            selectDeviceAuthMode(30, deviceSecure = true, null, null),
        )
        assertEquals(
            DeviceAuthMode.RejectUnavailable,
            selectDeviceAuthMode(30, deviceSecure = true, 11, 11),
        )
    }

    @Test
    fun homeDismissalUsesBackgroundedMessage() {
        val failure = classifyBiometricCancellation(BIOMETRIC_ERROR_USER_CANCELED, userLeaving = true)
        assertEquals("backgrounded", failure.code)
        assertEquals("應用程式已離開前景，請重新驗證", failure.message)
    }

    @Test
    fun explicitCancelStaysCancelledWhileVisible() {
        val failure = classifyBiometricCancellation(BIOMETRIC_ERROR_NEGATIVE_BUTTON, userLeaving = false)
        assertEquals("cancelled", failure.code)
        assertEquals("已取消裝置驗證", failure.message)
    }

    @Test
    fun otherErrorsStayFailedWhileVisible() {
        val failure = classifyBiometricCancellation(errorCode = 1, userLeaving = false)
        assertEquals("authentication_failed", failure.code)
        assertEquals("裝置驗證未完成，金庫仍鎖定", failure.message)
    }
}
