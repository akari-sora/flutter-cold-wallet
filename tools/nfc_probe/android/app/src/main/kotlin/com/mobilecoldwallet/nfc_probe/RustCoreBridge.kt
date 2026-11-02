package com.mobilecoldwallet.nfc_probe

import java.io.File

private object NativeLibraryLoader {
    private val loaded = HashSet<String>()

    @Synchronized
    fun ensureLoaded(baseName: String): Boolean {
        if (loaded.contains(baseName)) return true
        try {
            System.loadLibrary(baseName)
            loaded.add(baseName)
            return true
        } catch (_: UnsatisfiedLinkError) {
            // Fallback for host JVM unit tests (`./gradlew testDebugUnitTest`)
            val osName = System.getProperty("os.name")?.lowercase() ?: ""
            val fileNames = when {
                osName.contains("win") -> listOf("${baseName}.dll", "lib${baseName}.dll")
                osName.contains("mac") -> listOf("lib${baseName}.dylib")
                else -> listOf("lib${baseName}.so")
            }

            val cwd = File(System.getProperty("user.dir") ?: ".")
            val searchRoots = listOfNotNull(
                cwd,
                cwd.parentFile,
                cwd.parentFile?.parentFile,
                cwd.parentFile?.parentFile?.parentFile,
                cwd.parentFile?.parentFile?.parentFile?.parentFile
            )

            for (root in searchRoots) {
                for (profile in listOf("debug", "release")) {
                    for (fname in fileNames) {
                        val candidate = File(root, "target/$profile/$fname")
                        if (candidate.isFile) {
                            try {
                                System.load(candidate.absolutePath)
                                loaded.add(baseName)
                                return true
                            } catch (_: Throwable) {
                            }
                        }
                    }
                }
            }
        }
        return false
    }
}

/**
 * Offline Vault JNI Bridge (`libvault_ffi`).
 * Connects Android HCE (`FcwHostApduService`) to the Rust core `SessionManager`,
 * `ApduFrameAssembler`, `PreparedRequest`, and `KeyVault`.
 */
object VaultCoreBridge {
    val isAvailable: Boolean by lazy { NativeLibraryLoader.ensureLoaded("vault_ffi") }

    @JvmStatic
    external fun nativeInit(): Int

    @JvmStatic
    external fun nativeLoadTestMnemonic(phrase: String, passphrase: String): Int

    @JvmStatic
    external fun nativeProcessApduFrame(apduHex: String): String

    @JvmStatic
    external fun nativePrepareLegacyTxWithTransport(
        sessionId: String,
        requestId: String,
        rawRlpHex: String,
        declaredChainId: Long,
        transportCode: Int
    ): String

    @JvmStatic
    external fun nativePrepareEip1559TxWithTransport(
        sessionId: String,
        requestId: String,
        rawRlpHex: String,
        declaredChainId: Long,
        transportCode: Int
    ): String

    @JvmStatic
    external fun nativeApproveAndSign(handleId: String): String

    @JvmStatic
    external fun nativeCancel(handleId: String): Int

    @JvmStatic
    external fun nativeCancelJson(handleId: String): String

    @JvmStatic
    external fun nativeGetRequestState(handleId: String): String

    @JvmStatic
    external fun nativeChunkPayload(
        sessionId: String,
        requestId: String,
        messageKind: Int,
        rawPayloadHex: String,
        chunkSize: Int
    ): String

    @JvmStatic
    external fun nativeGetPrimitiveSignCount(): Long

    @JvmStatic
    external fun nativeResetNfcSessions(): Int
}

/**
 * Watch-Only Wallet JNI Bridge (`libwallet_ffi`).
 * Connects Android Reader (`MainActivity` IsoDep) to watch-only transaction intent registration,
 * Tier-2 APDU framing (`Lc <= 128`), response reassembly, and bound cryptographic verification.
 * Never loads or links private key material (`vault_ffi`).
 */
object WalletCoreBridge {
    val isAvailable: Boolean by lazy { NativeLibraryLoader.ensureLoaded("wallet_ffi") }

    @JvmStatic
    external fun nativeInit(): Int

    @JvmStatic
    external fun nativeRegisterPendingTx(
        sessionId: String,
        requestId: String,
        rawRlpHex: String,
        declaredChainId: Long,
        expectedAddress: String
    ): String

    @JvmStatic
    external fun nativeChunkPayload(
        sessionId: String,
        requestId: String,
        messageKind: Int,
        rawPayloadHex: String,
        chunkSize: Int
    ): String

    @JvmStatic
    external fun nativeProcessApduFrame(apduHex: String): String

    @JvmStatic
    external fun nativeVerifyNfcResponse(
        sessionId: String,
        requestId: String,
        responsePayloadHex: String
    ): String

    @JvmStatic
    external fun nativeResetTransportAssembler(sessionId: String): Int
}
