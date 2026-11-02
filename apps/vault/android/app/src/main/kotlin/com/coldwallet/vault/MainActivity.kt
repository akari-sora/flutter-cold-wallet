package com.coldwallet.vault

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

class MainActivity : FlutterActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private var authResult: MethodChannel.Result? = null
    private var authCancellation: CancellationSignal? = null
    private var authGeneration = 0
    private var authKeyAlias: String = AUTH_KEY
    private var fileResult: MethodChannel.Result? = null
    private var cameraPermissionResult: MethodChannel.Result? = null
    private var cameraPermissionRequestCode: Int? = null
    private var nextCameraPermissionRequestCode = CAMERA_PERMISSION_FIRST
    private val cameraPermissionTimeout = Runnable { finishCameraPermission(false) }
    private var backupJson: String? = null
    private var userLeaving = false
    private val timeout = Runnable { rejectAuth("timeout", "裝置驗證逾時，請重試") }

    override fun onUserLeaveHint() {
        userLeaving = true
        super.onUserLeaveHint()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fcw/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "storageDirectory" -> result.success(noBackupFilesDir.absolutePath)
                    "hasCameraPermission" -> result.success(hasCameraPermission())
                    "requestCameraPermission" -> requestCameraPermission(result)
                    "cancelCameraPermissionRequest" -> {
                        finishCameraPermission(false)
                        result.success(true)
                    }
                    "openAppSettings" -> openAppSettings(result)
                    "authenticateWithDevice" -> authenticate(result)
                    "cancelDeviceAuthentication" -> {
                        rejectAuth("cancelled", "已取消裝置驗證")
                        result.success(true)
                    }
                    "saveEncryptedBackup" -> {
                        val json = call.argument<String>("json")
                        if (json == null || json.toByteArray(Charsets.UTF_8).size > MAX_BACKUP_BYTES) {
                            result.error("invalid_backup", "備份資料不存在或超過大小限制", null)
                        } else openBackupPicker(result, json)
                    }
                    "readEncryptedBackup" -> openBackupPicker(result, null)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasCameraPermission(): Boolean =
        checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    // Permission preparation only. Dart locks/clears the Vault before calling;
    // a successful result never authenticates or restores a signing session.
    private fun requestCameraPermission(result: MethodChannel.Result) {
        if (cameraPermissionResult != null || authResult != null || fileResult != null) {
            result.error("busy", "請先完成目前的操作", null)
            return
        }
        val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        if (keyguard.isKeyguardLocked) {
            result.success(false)
            return
        }
        if (hasCameraPermission()) {
            result.success(true)
            return
        }
        if (nextCameraPermissionRequestCode > CAMERA_PERMISSION_LAST) {
            result.error("camera_permission_unavailable", "請重新開啟金庫後準備相機權限", null)
            return
        }
        val requestCode = nextCameraPermissionRequestCode++
        cameraPermissionRequestCode = requestCode
        cameraPermissionResult = result
        handler.postDelayed(cameraPermissionTimeout, 60_000)
        try {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), requestCode)
        } catch (_: Exception) {
            finishCameraPermission(false)
        }
    }

    private fun finishCameraPermission(granted: Boolean, permanentlyDenied: Boolean = false) {
        val result = cameraPermissionResult
        cameraPermissionResult = null
        cameraPermissionRequestCode = null
        handler.removeCallbacks(cameraPermissionTimeout)
        if (permanentlyDenied) {
            result?.error("camera_permission_permanently_denied", "相機權限需在系統設定中允許", null)
        } else {
            result?.success(granted)
        }
    }

    // Only the system settings page can grant a permission Android no longer
    // asks for. Leaving the foreground locks the Vault on the Dart side.
    private fun openAppSettings(result: MethodChannel.Result) {
        if (cameraPermissionResult != null || authResult != null || fileResult != null) {
            result.error("busy", "請先完成目前的操作", null)
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null),
                ),
            )
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != cameraPermissionRequestCode) return
        val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        // No rationale right after a denial means Android will not show the
        // dialog again ("don't ask again", repeated denial or policy). A
        // dismissed first dialog looks the same, so Dart words it as "may".
        val permanentlyDenied =
            grantResults.firstOrNull() == PackageManager.PERMISSION_DENIED &&
                !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)
        finishCameraPermission(
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED &&
                hasCameraPermission() && !keyguard.isKeyguardLocked,
            permanentlyDenied,
        )
    }

    private fun authenticate(result: MethodChannel.Result) {
        if (authResult != null || fileResult != null || cameraPermissionResult != null) {
            result.error("busy", "請先完成目前的操作", null)
            return
        }
        val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        val deviceSecure = keyguard.isDeviceSecure
        val sdkInt = Build.VERSION.SDK_INT
        var strongBiometricStatus: Int? = null
        var deviceCredentialStatus: Int? = null
        if (sdkInt >= Build.VERSION_CODES.R) {
            val biometricManager = getSystemService(BiometricManager::class.java)
            strongBiometricStatus = biometricManager.canAuthenticate(
                BiometricManager.Authenticators.BIOMETRIC_STRONG,
            )
            deviceCredentialStatus = biometricManager.canAuthenticate(
                BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        }
        val mode = selectDeviceAuthMode(
            sdkInt,
            deviceSecure,
            strongBiometricStatus,
            deviceCredentialStatus,
        )
        when (mode) {
            DeviceAuthMode.RejectNotSecure -> {
                result.error("device_not_secure", "請先設定裝置鎖定密碼", null)
                return
            }
            DeviceAuthMode.RejectUnavailable -> {
                result.error(
                    "authentication_unavailable",
                    "此裝置沒有可用的生物識別或鎖定密碼驗證",
                    null,
                )
                return
            }
            DeviceAuthMode.StrongOrCredential -> authKeyAlias = AUTH_KEY
            DeviceAuthMode.CredentialOnly -> authKeyAlias = AUTH_KEY_CREDENTIAL
            DeviceAuthMode.Api29CredentialAllowed,
            DeviceAuthMode.Api28BiometricOnly,
            -> authKeyAlias = AUTH_KEY
        }
        userLeaving = false
        authResult = result
        val generation = ++authGeneration
        handler.postDelayed(timeout, 60_000)
        try {
            ensureAuthenticationKey(mode)
            val cancellation = CancellationSignal()
            authCancellation = cancellation
            val builder = BiometricPrompt.Builder(this)
                .setTitle("解鎖離線金庫")
            when (mode) {
                DeviceAuthMode.StrongOrCredential -> {
                    builder.setSubtitle("使用裝置生物識別或鎖定密碼驗證")
                    builder.setAllowedAuthenticators(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or
                            BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                    )
                }
                DeviceAuthMode.CredentialOnly -> {
                    builder.setSubtitle("使用裝置鎖定密碼驗證")
                    builder.setAllowedAuthenticators(BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                }
                DeviceAuthMode.Api29CredentialAllowed -> {
                    builder.setSubtitle("使用裝置生物識別或鎖定密碼驗證")
                    @Suppress("DEPRECATION")
                    builder.setDeviceCredentialAllowed(true)
                }
                DeviceAuthMode.Api28BiometricOnly -> {
                    builder.setSubtitle("使用裝置生物識別或鎖定密碼驗證")
                    // Android 9's native prompt has no credential fallback. A weak
                    // biometric cannot authorize our authentication-bound key.
                    builder.setNegativeButton("取消", mainExecutor) { _, _ ->
                        if (generation == authGeneration) rejectAuth("cancelled", "已取消裝置驗證")
                    }
                }
                else -> throw IllegalStateException("unexpected auth mode")
            }
            builder.build().authenticate(cancellation, mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(value: BiometricPrompt.AuthenticationResult) {
                        completeAuthentication(generation)
                    }
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        if (generation != authGeneration) return
                        val failure = classifyBiometricCancellation(code, userLeaving)
                        rejectAuth(failure.code, failure.message)
                    }
                })
        } catch (error: Exception) {
            rejectAuth("authentication_unavailable", "無法執行裝置驗證")
        }
    }

    // A KeyStore gate verifies recent system authentication. Asset signing stays
    // in Rust; this gate does not make this a hardware asset signing device.
    private fun ensureAuthenticationKey(mode: DeviceAuthMode) {
        val alias = authKeyAlias
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(alias)) return
        val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
        when (mode) {
            DeviceAuthMode.StrongOrCredential -> {
                builder.setUserAuthenticationParameters(
                    5,
                    KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
                )
            }
            DeviceAuthMode.CredentialOnly -> {
                builder.setUserAuthenticationParameters(5, KeyProperties.AUTH_DEVICE_CREDENTIAL)
            }
            DeviceAuthMode.Api29CredentialAllowed,
            DeviceAuthMode.Api28BiometricOnly,
            -> {
                @Suppress("DEPRECATION")
                builder.setUserAuthenticationValidityDurationSeconds(5)
            }
            else -> throw IllegalStateException("unexpected auth mode")
        }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(builder.build())
            generateKey()
        }
    }

    private fun completeAuthentication(generation: Int) {
        if (generation != authGeneration || authResult == null || isFinishing || isDestroyed) return
        try {
            val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
            if (keyguard.isKeyguardLocked) throw IllegalStateException("裝置已鎖定")
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val key = store.getKey(authKeyAlias, null) as SecretKey
            Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, key)
                doFinal(byteArrayOf(0x46, 0x43, 0x57))
            }
            val result = authResult
            clearAuthentication()
            result?.success(true)
        } catch (error: Exception) {
            rejectAuth("authentication_failed", "裝置金鑰驗證失敗，請重新驗證")
        }
    }

    private fun rejectAuth(code: String, message: String) {
        val result = authResult
        clearAuthentication()
        result?.error(code, message, null)
    }

    private fun clearAuthentication() {
        authGeneration++
        authResult = null
        handler.removeCallbacks(timeout)
        authCancellation?.cancel()
        authCancellation = null
    }

    private fun openBackupPicker(result: MethodChannel.Result, json: String?) {
        if (fileResult != null || authResult != null || cameraPermissionResult != null) {
            result.error("busy", "請先完成目前的操作", null)
            return
        }
        fileResult = result
        backupJson = json
        val intent = Intent(if (json == null) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            if (json != null) putExtra(Intent.EXTRA_TITLE, "fcw-vault-encrypted-backup.json")
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, if (json == null) READ_BACKUP else WRITE_BACKUP)
        } catch (error: Exception) {
            fileResult = null
            backupJson = null
            result.error("picker_unavailable", "無法開啟本機檔案選擇器", null)
        }
    }

    @Deprecated("Android activity result interop")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != READ_BACKUP && requestCode != WRITE_BACKUP) return
        val result = fileResult ?: return
        val json = backupJson
        fileResult = null
        backupJson = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.error("cancelled", "已取消備份檔案操作", null)
            return
        }
        try {
            if (requestCode == WRITE_BACKUP) {
                val bytes = requireNotNull(json).toByteArray(Charsets.UTF_8)
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output).write(bytes)
                    output.flush()
                }
                result.success(true)
            } else {
                val bytes = contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input).readBytesLimited(MAX_BACKUP_BYTES)
                }
                result.success(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString())
            }
        } catch (error: Exception) {
            result.error("backup_io_failed", "讀寫備份失敗：檔案無效、過大或無法存取", null)
        }
    }

    private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit)
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    override fun onStop() {
        userLeaving = true
        finishCameraPermission(false)
        super.onStop()
    }

    override fun onDestroy() {
        finishCameraPermission(false)
        rejectAuth("cancelled", "金庫視窗已關閉")
        fileResult?.error("cancelled", "金庫視窗已關閉", null)
        fileResult = null
        backupJson = null
        super.onDestroy()
    }

    companion object {
        private const val AUTH_KEY = "fcw-device-auth-v1"
        private const val AUTH_KEY_CREDENTIAL = "fcw-device-auth-v1-credential"
        private const val READ_BACKUP = 4102
        private const val WRITE_BACKUP = 4103
        private const val CAMERA_PERMISSION_FIRST = 0x6000
        private const val CAMERA_PERMISSION_LAST = 0x7fff
        private const val MAX_BACKUP_BYTES = 2 * 1024 * 1024
    }
}
