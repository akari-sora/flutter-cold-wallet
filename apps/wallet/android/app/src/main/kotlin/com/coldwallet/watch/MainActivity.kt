package com.coldwallet.watch

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var fileResult: MethodChannel.Result? = null
    private var backupJson: String? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fcw/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "storageDirectory" -> result.success(filesDir.absolutePath)
                    "savePublicBackup" -> {
                        val json = call.argument<String>("json")
                        if (json == null || json.toByteArray(Charsets.UTF_8).size > MAX_BACKUP_BYTES) {
                            result.error("invalid_backup", "公開帳戶備份不存在或超過大小限制", null)
                        } else openBackupPicker(result, json)
                    }
                    "readPublicBackup" -> openBackupPicker(result, null)
                    "openAppSettings" -> openAppSettings(result)
                    else -> result.notImplemented()
                }
            }
    }

    // A permanently denied camera permission can only be re-enabled here.
    private fun openAppSettings(result: MethodChannel.Result) {
        // As in the Vault: never start Settings over a pending picker result.
        if (fileResult != null) {
            result.error("busy", "請先完成目前的操作", null)
            return
        }
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null)
        )
        try {
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("settings_unavailable", "無法開啟系統設定", null)
        }
    }

    private fun openBackupPicker(result: MethodChannel.Result, json: String?) {
        if (fileResult != null) {
            result.error("busy", "請先完成目前的操作", null)
            return
        }
        fileResult = result
        backupJson = json
        val intent = Intent(if (json == null) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            if (json != null) putExtra(Intent.EXTRA_TITLE, "fcw-watch-only-backup.json")
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

    override fun onDestroy() {
        fileResult?.error("cancelled", "Wallet 視窗已關閉", null)
        fileResult = null
        backupJson = null
        super.onDestroy()
    }

    companion object {
        private const val READ_BACKUP = 4202
        private const val WRITE_BACKUP = 4203
        private const val MAX_BACKUP_BYTES = 2 * 1024 * 1024
    }
}
