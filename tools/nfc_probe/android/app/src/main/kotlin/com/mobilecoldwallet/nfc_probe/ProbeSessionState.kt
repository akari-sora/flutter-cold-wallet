package com.mobilecoldwallet.nfc_probe

import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/**
 * Shared session identity and local evidence persistence across MainActivity (Reader),
 * TestControlProvider (authenticated test controller), and FcwHostApduService (HCE).
 *
 * Ensures that Reader, HCE, and Runner share a coherent (run_id, phase, role, generation, token)
 * contract and that every intermediate and terminal event is persisted locally on the device
 * with a strictly serialized, monotonically increasing event_seq.
 */
object ProbeSessionState {
    private const val TAG = "FCW_NFC_PROBE"
    private const val MAX_BUFFERED_EVENTS = 512

    data class SessionSnapshot(
        val runId: String,
        val phase: String,
        val role: MainActivity.Role,
        val generation: Long,
        val activeToken: Long,
        val eventSeq: Long
    )

    data class ReportWriteResult(
        val ok: Boolean,
        val file: File?,
        val errorCode: String?,
        val errorMessage: String?
    )

    data class EventsReadResult(
        val valid: Boolean,
        val events: List<JSONObject>,
        val errorCode: String?,
        val errorMessage: String?
    ) {
        val ok: Boolean get() = valid
        val status: String get() = errorCode ?: "OK"
        val errorDetail: String get() = errorMessage ?: ""
    }

    private val stateLock = Any()
    private val activeTokenCounter = AtomicLong(1L)
    private val generationCounter = AtomicLong(1L)
    private val eventSeqCounter = AtomicLong(0L)

    @Volatile
    private var currentRunId: String = UUID.randomUUID().toString()

    @Volatile
    private var currentPhase: String = "local_ui"

    @Volatile
    private var currentRole: MainActivity.Role = MainActivity.Role.HCE

    @Volatile
    private var evidenceRootDir: File? = null

    @Volatile
    var lastPersistenceError: String? = null
        private set

    private val currentRunEvents = ArrayList<JSONObject>()
    private val runEventSeqCounters = HashMap<String, Long>()
    private val runTerminalStatus = HashMap<String, String>()

    fun configureEvidenceDirectory(baseFilesDir: File?) {
        if (baseFilesDir == null) return
        synchronized(stateLock) {
            val dir = File(baseFilesDir, "nfc_probe_evidence")
            if (!dir.exists()) {
                dir.mkdirs()
            }
            evidenceRootDir = dir
        }
    }

    fun getEvidenceDirectory(): File? = evidenceRootDir

    fun snapshot(): SessionSnapshot {
        synchronized(stateLock) {
            return snapshotLocked()
        }
    }

    private fun snapshotLocked(): SessionSnapshot {
        return SessionSnapshot(
            runId = currentRunId,
            phase = currentPhase,
            role = currentRole,
            generation = generationCounter.get(),
            activeToken = activeTokenCounter.get(),
            eventSeq = eventSeqCounter.get()
        )
    }

    /**
     * Starts a new run/generation and invalidates any previous active token.
     * Used by local UI Start/Role buttons and by authenticated TestControlProvider.
     */
    fun activateRun(
        role: MainActivity.Role,
        requestedRunId: String? = null,
        requestedPhase: String? = null,
        triggerSource: String
    ): SessionSnapshot {
        synchronized(stateLock) {
            val sanitizedRunId = requestedRunId?.trim()?.takeIf { it.isNotEmpty() }
                ?: UUID.randomUUID().toString()
            val sanitizedPhase = requestedPhase?.trim()?.takeIf { it.isNotEmpty() }
                ?: "local_ui"

            currentRunId = sanitizedRunId
            currentPhase = sanitizedPhase
            currentRole = role
            val newGen = generationCounter.incrementAndGet()
            val newToken = activeTokenCounter.incrementAndGet()
            currentRunEvents.clear()

            val snap = SessionSnapshot(
                runId = currentRunId,
                phase = currentPhase,
                role = currentRole,
                generation = newGen,
                activeToken = newToken,
                eventSeq = eventSeqCounter.get()
            )

            recordAndLogEvent(
                eventName = "PROBE_CONTROL_ACK",
                source = triggerSource,
                payload = JSONObject().apply {
                    put("ack", true)
                    put("run_id", snap.runId)
                    put("phase", snap.phase)
                    put("role", snap.role.name)
                    put("generation", snap.generation)
                    put("token", snap.activeToken)
                    put("trigger_source", triggerSource)
                },
                snapshotOverride = snap
            )
            return snap
        }
    }

    /**
     * Invalidates the active token and increments generation without necessarily keeping old I/O alive.
     */
    fun invalidate(reason: String, startFreshRunId: Boolean = false): SessionSnapshot {
        synchronized(stateLock) {
            val oldToken = activeTokenCounter.get()
            val newToken = activeTokenCounter.incrementAndGet()
            val newGen = generationCounter.incrementAndGet()
            if (startFreshRunId) {
                currentRunId = UUID.randomUUID().toString()
                currentRunEvents.clear()
            }
            val snap = SessionSnapshot(
                runId = currentRunId,
                phase = currentPhase,
                role = currentRole,
                generation = newGen,
                activeToken = newToken,
                eventSeq = eventSeqCounter.get()
            )
            recordAndLogEvent(
                eventName = "SESSION_INVALIDATED",
                source = "SESSION_MANAGER",
                payload = JSONObject().apply {
                    put("reason", reason)
                    put("invalidated_token", oldToken)
                    put("new_token", newToken)
                    put("new_generation", newGen)
                    put("run_id", snap.runId)
                    put("phase", snap.phase)
                },
                snapshotOverride = snap
            )
            return snap
        }
    }

    fun nextEventSeq(): Long = synchronized(stateLock) { eventSeqCounter.incrementAndGet() }

    fun elapsedRealtimeSafe(): Long {
        return try {
            val t = SystemClock.elapsedRealtime()
            if (t > 0L) t else System.currentTimeMillis()
        } catch (_: Throwable) {
            System.currentTimeMillis()
        }
    }

    /**
     * Allocates `event_seq`, enriches the event JSON, appends to in-memory buffer,
     * and appends to `events_<run_id>.jsonl` ALL inside `synchronized(stateLock)` so
     * concurrent Reader and HCE threads can never write out-of-order `event_seq` lines.
     */
    fun recordAndLogEvent(
        eventName: String,
        source: String,
        payload: JSONObject,
        snapshotOverride: SessionSnapshot? = null
    ): JSONObject {
        val enriched: JSONObject
        var writeFailureLog: JSONObject? = null

        synchronized(stateLock) {
            val snap = snapshotOverride ?: snapshotLocked()
            val seq = eventSeqCounter.incrementAndGet()
            val runIdForEvent = payload.optString("run_id").takeIf { it.isNotEmpty() } ?: snap.runId
            val nextRunSeq = (runEventSeqCounters[runIdForEvent] ?: 0L) + 1L
            runEventSeqCounters[runIdForEvent] = nextRunSeq

            enriched = JSONObject(payload.toString()).apply {
                put("event", eventName)
                if (!has("source")) put("source", source)
                if (!has("run_id") || optString("run_id").isEmpty()) put("run_id", runIdForEvent)
                if (!has("phase") || optString("phase").isEmpty()) put("phase", snap.phase)
                if (!has("role") || optString("role").isEmpty()) put("role", snap.role.name)
                if (!has("generation") || optLong("generation", 0L) <= 0L) put("generation", snap.generation)
                if (!has("token") || optLong("token", 0L) <= 0L) put("token", snap.activeToken)
                put("event_seq", seq)
                put("run_event_seq", nextRunSeq)
                if (!has("timestamp_elapsed_ms")) {
                    put("timestamp_elapsed_ms", elapsedRealtimeSafe())
                }
                if (!has("timestamp_wall_ms")) {
                    put("timestamp_wall_ms", System.currentTimeMillis())
                }
            }

            if (currentRunEvents.size >= MAX_BUFFERED_EVENTS) {
                currentRunEvents.removeAt(0)
            }
            currentRunEvents.add(enriched)

            val writeErr = persistEventLineLocked(runIdForEvent, enriched)
            if (writeErr != null) {
                lastPersistenceError = writeErr
                enriched.put("evidence_write_error", "EVIDENCE_WRITE_FAILED")
                enriched.put("evidence_write_error_detail", writeErr)
                writeFailureLog = JSONObject().apply {
                    put("event", "EVIDENCE_WRITE_FAILED")
                    put("run_id", runIdForEvent)
                    put("target_event", eventName)
                    put("event_seq", seq)
                    put("error_code", "EVIDENCE_WRITE_FAILED")
                    put("error_detail", writeErr)
                }
            }
        }

        try {
            Log.i(TAG, enriched.toString())
            if (writeFailureLog != null) {
                Log.e(TAG, writeFailureLog.toString())
            }
        } catch (_: Throwable) {
        }
        return enriched
    }

    private fun persistEventLineLocked(runId: String, eventObj: JSONObject): String? {
        val dir = evidenceRootDir ?: return null
        return try {
            if (!dir.exists() && !dir.mkdirs()) {
                return "Failed to create evidence directory: ${dir.absolutePath}"
            }
            if (!dir.isDirectory) {
                return "Evidence root path is not a directory: ${dir.absolutePath}"
            }
            val safeId = sanitizeId(runId)
            val jsonlFile = File(dir, "events_${safeId}.jsonl")
            if (jsonlFile.exists() && jsonlFile.isDirectory) {
                return "Target JSONL path is a directory: ${jsonlFile.absolutePath}"
            }
            jsonlFile.appendText(eventObj.toString() + "\n", Charsets.UTF_8)
            null
        } catch (t: Throwable) {
            "${t.javaClass.simpleName}: ${t.message ?: "unknown write error"}"
        }
    }

    private fun atomicMoveReplace(tmpFile: File, targetFile: File) {
        if (targetFile.exists() && targetFile.isDirectory) {
            throw IOException("Target report path is a directory: ${targetFile.absolutePath}")
        }
        val src = tmpFile.toPath()
        val dst = targetFile.toPath()
        try {
            Files.move(src, dst, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
            Files.move(src, dst, StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private fun isNegativeTerminalStatus(status: String): Boolean {
        val s = status.uppercase()
        return s.contains("CANCEL") || s.contains("ABORT") || s.contains("FAIL") || s.contains("REJECT")
    }

    private fun isPositivePassStatus(status: String, summaryPayload: JSONObject): Boolean {
        val s = status.uppercase()
        return s == "PASSED" || s == "VERIFIED" || summaryPayload.optBoolean("all_passed", false) || summaryPayload.optBoolean("verified", false)
    }

    fun writePersistentReportDetailed(
        role: String,
        runId: String,
        phase: String,
        generation: Long,
        summaryPayload: JSONObject
    ): ReportWriteResult {
        synchronized(stateLock) {
            val safeRole = role.lowercase()
            val terminalKey = "${safeRole}:${runId}:${generation}"
            val incomingStatus = summaryPayload.optString("status", "")
            val existingTerminal = runTerminalStatus[terminalKey]

            // Terminal state precedence: once CANCELLED / ABORTED_STALE / FAILED is recorded for a run+generation,
            // a stale PASSED/VERIFIED report can never overwrite it.
            if (existingTerminal != null && isNegativeTerminalStatus(existingTerminal) && isPositivePassStatus(incomingStatus, summaryPayload)) {
                return ReportWriteResult(
                    ok = false,
                    file = null,
                    errorCode = "STALE_PASS_REJECTED_AFTER_TERMINAL_FAILURE",
                    errorMessage = "Run $runId gen $generation already terminated with $existingTerminal; refusing to overwrite with $incomingStatus"
                )
            }
            if (incomingStatus.isNotEmpty() && (isNegativeTerminalStatus(incomingStatus) || isPositivePassStatus(incomingStatus, summaryPayload))) {
                runTerminalStatus[terminalKey] = incomingStatus
            }

            val eventsArray = JSONArray()
            for (evt in currentRunEvents) {
                if (evt.optString("run_id") == runId) {
                    eventsArray.put(evt)
                }
            }
            val fullReport = JSONObject(summaryPayload.toString()).apply {
                put("run_id", runId)
                put("phase", phase)
                put("role", role)
                put("generation", generation)
                put("persisted_at_wall_ms", System.currentTimeMillis())
                put("events_count", eventsArray.length())
                put("events", eventsArray)
            }

            val dir = evidenceRootDir
            if (dir == null) {
                return ReportWriteResult(
                    ok = false,
                    file = null,
                    errorCode = "EVIDENCE_DIR_UNCONFIGURED",
                    errorMessage = "Evidence root directory is not configured"
                )
            }

            return try {
                if (!dir.exists() && !dir.mkdirs()) {
                    throw IOException("Cannot create evidence directory ${dir.absolutePath}")
                }
                if (!dir.isDirectory) {
                    throw IOException("Evidence root path is not a directory: ${dir.absolutePath}")
                }
                val safeId = sanitizeId(runId)
                val reportFile = File(dir, "report_${safeRole}_${safeId}.json")
                val tmpFile = File(dir, "report_${safeRole}_${safeId}.json.tmp")

                fullReport.put("evidence_file_path", reportFile.absolutePath)
                fullReport.put("evidence_write_status", "OK")
                val serialized = fullReport.toString(2)

                tmpFile.writeText(serialized, Charsets.UTF_8)
                atomicMoveReplace(tmpFile, reportFile)

                val latestFile = File(dir, "latest_${safeRole}_report.json")
                val latestTmp = File(dir, "latest_${safeRole}_report.json.tmp")
                latestTmp.writeText(serialized, Charsets.UTF_8)
                atomicMoveReplace(latestTmp, latestFile)

                summaryPayload.put("evidence_file_path", reportFile.absolutePath)
                summaryPayload.put("evidence_write_status", "OK")
                ReportWriteResult(ok = true, file = reportFile, errorCode = null, errorMessage = null)
            } catch (t: Throwable) {
                val msg = "${t.javaClass.simpleName}: ${t.message ?: "unknown report write failure"}"
                lastPersistenceError = msg
                summaryPayload.put("evidence_write_status", "EVIDENCE_WRITE_FAILED")
                summaryPayload.put("evidence_write_error", msg)
                try {
                    Log.e(
                        TAG,
                        JSONObject().apply {
                            put("event", "EVIDENCE_WRITE_FAILED")
                            put("role", role)
                            put("run_id", runId)
                            put("generation", generation)
                            put("error_code", "EVIDENCE_WRITE_FAILED")
                            put("error_detail", msg)
                        }.toString()
                    )
                } catch (_: Throwable) {
                }
                ReportWriteResult(
                    ok = false,
                    file = null,
                    errorCode = "EVIDENCE_WRITE_FAILED",
                    errorMessage = msg
                )
            }
        }
    }

    fun writePersistentReport(
        role: String,
        runId: String,
        phase: String,
        generation: Long,
        summaryPayload: JSONObject
    ): File? {
        return writePersistentReportDetailed(role, runId, phase, generation, summaryPayload).file
    }

    /**
     * Reads and strictly validates `events_<run_id>.jsonl`.
     * Rejects malformed JSON lines, missing/non-positive `event_seq`, non-increasing `event_seq`,
     * or gaps in `run_event_seq` / `event_seq` with `EVIDENCE_CORRUPTED_OR_MISSING_EVENT`.
     */
    fun readAndValidateEventsForRun(runId: String): EventsReadResult {
        synchronized(stateLock) {
            val dir = evidenceRootDir
            if (dir != null) {
                val safeId = sanitizeId(runId)
                val jsonlFile = File(dir, "events_${safeId}.jsonl")
                if (jsonlFile.exists()) {
                    if (!jsonlFile.isFile) {
                        return EventsReadResult(
                            valid = false,
                            events = emptyList(),
                            errorCode = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT",
                            errorMessage = "JSONL path is not a regular file: ${jsonlFile.absolutePath}"
                        )
                    }
                    val lines = try {
                        jsonlFile.readLines(Charsets.UTF_8)
                    } catch (t: Throwable) {
                        return EventsReadResult(
                            valid = false,
                            events = emptyList(),
                            errorCode = "EVIDENCE_READ_FAILED",
                            errorMessage = "${t.javaClass.simpleName}: ${t.message}"
                        )
                    }
                    val parsed = ArrayList<JSONObject>()
                    var prevEventSeq: Long? = null
                    var prevRunEventSeq: Long? = null
                    var lineNo = 0
                    for (rawLine in lines) {
                        lineNo++
                        if (rawLine.isBlank()) continue
                        val obj = try {
                            JSONObject(rawLine)
                        } catch (t: Throwable) {
                            return EventsReadResult(
                                valid = false,
                                events = parsed,
                                errorCode = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT",
                                errorMessage = "Malformed JSON at line $lineNo in ${jsonlFile.name}: ${t.message}"
                            )
                        }
                        val seq = obj.optLong("event_seq", -1L)
                        if (seq <= 0L) {
                            return EventsReadResult(
                                valid = false,
                                events = parsed,
                                errorCode = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT",
                                errorMessage = "Missing or non-positive event_seq at line $lineNo in ${jsonlFile.name}"
                            )
                        }
                        if (prevEventSeq != null && seq <= prevEventSeq) {
                            return EventsReadResult(
                                valid = false,
                                events = parsed,
                                errorCode = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT",
                                errorMessage = "Non-monotonic event_seq ($prevEventSeq -> $seq) at line $lineNo in ${jsonlFile.name}"
                            )
                        }
                        val runSeq = obj.optLong("run_event_seq", -1L)
                        if (runSeq > 0L) {
                            val expectedRunSeq = (prevRunEventSeq ?: 0L) + 1L
                            if (runSeq != expectedRunSeq) {
                                return EventsReadResult(
                                    valid = false,
                                    events = parsed,
                                    errorCode = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT",
                                    errorMessage = "Missing or out-of-order run_event_seq (expected $expectedRunSeq, got $runSeq) at line $lineNo in ${jsonlFile.name}"
                                )
                            }
                            prevRunEventSeq = runSeq
                        } else if (prevEventSeq != null && seq != prevEventSeq + 1L) {
                            return EventsReadResult(
                                valid = false,
                                events = parsed,
                                errorCode = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT",
                                errorMessage = "Gap in event_seq ($prevEventSeq -> $seq) at line $lineNo in ${jsonlFile.name}"
                            )
                        }
                        prevEventSeq = seq
                        parsed.add(obj)
                    }
                    return EventsReadResult(valid = true, events = parsed, errorCode = null, errorMessage = null)
                }
            }
            val memEvents = currentRunEvents.filter { it.optString("run_id") == runId }
            return EventsReadResult(valid = true, events = memEvents, errorCode = null, errorMessage = null)
        }
    }

    fun readEventsForRun(runId: String): List<JSONObject> {
        val res = readAndValidateEventsForRun(runId)
        if (!res.valid) {
            throw IllegalStateException("${res.errorCode}: ${res.errorMessage}")
        }
        return res.events
    }

    /**
     * Discovers all persisted historical runs in `evidenceRootDir` across app restarts (`A7`).
     * Ordered newest-first by last modified timestamp.
     */
    fun listPersistedRuns(): JSONArray {
        synchronized(stateLock) {
            val out = JSONArray()
            val dir = evidenceRootDir ?: return out
            if (!dir.isDirectory) return out

            val runIds = LinkedHashSet<String>()
            val files = dir.listFiles() ?: emptyArray()
            val sortedFiles = files.sortedByDescending { it.lastModified() }
            for (f in sortedFiles) {
                val name = f.name
                when {
                    name.startsWith("events_") && name.endsWith(".jsonl") -> {
                        val id = name.removePrefix("events_").removeSuffix(".jsonl")
                        if (id.isNotEmpty()) runIds.add(id)
                    }
                    name.startsWith("report_reader_") && name.endsWith(".json") -> {
                        val id = name.removePrefix("report_reader_").removeSuffix(".json")
                        if (id.isNotEmpty()) runIds.add(id)
                    }
                    name.startsWith("report_hce_") && name.endsWith(".json") -> {
                        val id = name.removePrefix("report_hce_").removeSuffix(".json")
                        if (id.isNotEmpty()) runIds.add(id)
                    }
                }
            }

            for (safeId in runIds) {
                val jsonlFile = File(dir, "events_${safeId}.jsonl")
                val readerReportFile = File(dir, "report_reader_${safeId}.json")
                val hceReportFile = File(dir, "report_hce_${safeId}.json")
                val evRes = if (jsonlFile.exists()) readAndValidateEventsForRun(safeId) else null
                val firstEvt = evRes?.events?.firstOrNull()
                val actualRunId = firstEvt?.optString("run_id")?.takeIf { it.isNotEmpty() } ?: safeId
                val lastModified = maxOf(
                    if (jsonlFile.exists()) jsonlFile.lastModified() else 0L,
                    if (readerReportFile.exists()) readerReportFile.lastModified() else 0L,
                    if (hceReportFile.exists()) hceReportFile.lastModified() else 0L
                )
                out.put(JSONObject().apply {
                    put("run_id", actualRunId)
                    put("safe_id", safeId)
                    put("has_events_jsonl", jsonlFile.isFile)
                    put("has_reader_report", readerReportFile.isFile)
                    put("has_hce_report", hceReportFile.isFile)
                    put("events_count", evRes?.events?.size ?: 0)
                    put("integrity_valid", evRes?.valid ?: false)
                    if (evRes?.errorCode != null) {
                        put("integrity_error_code", evRes.errorCode)
                        put("integrity_error_message", evRes.errorMessage)
                    }
                    put("last_modified_ms", lastModified)
                })
            }
            return out
        }
    }

    /**
     * Loads a complete, integrity-checked evidence bundle for a specific `runId` (including
     * historical runs persisted before an app restart).
     */
    fun loadPersistedRunBundle(requestedRunId: String? = null, preferredRole: String? = null): JSONObject {
        synchronized(stateLock) {
            val snap = snapshotLocked()
            val targetRunId = requestedRunId?.trim()?.takeIf { it.isNotEmpty() } ?: snap.runId
            val safeId = sanitizeId(targetRunId)
            val dir = evidenceRootDir
            val jsonlFile = if (dir != null) File(dir, "events_${safeId}.jsonl") else null
            val roleName = (preferredRole ?: snap.role.name).uppercase()
            val readerReportFile = if (dir != null) File(dir, "report_reader_${safeId}.json") else null
            val hceReportFile = if (dir != null) File(dir, "report_hce_${safeId}.json") else null
            val primaryReportFile = when {
                roleName == "READER" && readerReportFile?.isFile == true -> readerReportFile
                roleName == "HCE" && hceReportFile?.isFile == true -> hceReportFile
                readerReportFile?.isFile == true -> readerReportFile
                hceReportFile?.isFile == true -> hceReportFile
                else -> if (dir != null) File(dir, "report_${roleName.lowercase()}_${safeId}.json") else null
            }

            val evRes = readAndValidateEventsForRun(targetRunId)
            val eventsArr = JSONArray()
            for (e in evRes.events) {
                eventsArr.put(e)
            }

            var reportJson: JSONObject? = null
            var reportReadError: String? = null
            if (primaryReportFile != null && primaryReportFile.exists()) {
                try {
                    reportJson = JSONObject(primaryReportFile.readText(Charsets.UTF_8))
                } catch (t: Throwable) {
                    reportReadError = "Malformed report JSON (${primaryReportFile.name}): ${t.message}"
                }
            }

            val firstEvt = evRes.events.firstOrNull()
            val lastEvt = evRes.events.lastOrNull()
            val resolvedPhase = reportJson?.optString("phase")?.takeIf { it.isNotEmpty() }
                ?: lastEvt?.optString("phase")?.takeIf { it.isNotEmpty() }
                ?: if (targetRunId == snap.runId) snap.phase else "historical"
            val resolvedRole = reportJson?.optString("role")?.takeIf { it.isNotEmpty() }
                ?: lastEvt?.optString("role")?.takeIf { it.isNotEmpty() }
                ?: roleName
            val resolvedGen = reportJson?.optLong("generation", 0L)?.takeIf { it > 0L }
                ?: lastEvt?.optLong("generation", 0L)?.takeIf { it > 0L }
                ?: if (targetRunId == snap.runId) snap.generation else 0L
            val resolvedToken = lastEvt?.optLong("token", 0L)?.takeIf { it > 0L }
                ?: firstEvt?.optLong("token", 0L)?.takeIf { it > 0L }
                ?: if (targetRunId == snap.runId) snap.activeToken else 0L

            val status = when {
                !evRes.valid -> evRes.errorCode ?: "EVIDENCE_CORRUPTED_OR_MISSING_EVENT"
                lastPersistenceError != null && targetRunId == snap.runId -> "EVIDENCE_WRITE_FAILED"
                reportReadError != null -> "EVIDENCE_CORRUPTED_OR_MISSING_EVENT"
                evRes.events.isEmpty() && reportJson == null -> "EVIDENCE_NOT_FOUND"
                else -> "OK"
            }

            return JSONObject().apply {
                put("evidence_status", status)
                if (status != "OK") {
                    put("all_passed", false)
                    put("error_code", status)
                    put(
                        "error_detail",
                        evRes.errorMessage ?: reportReadError ?: lastPersistenceError ?: "No persisted events or report for run_id=$targetRunId"
                    )
                } else {
                    put("all_passed", reportJson?.optBoolean("all_passed", false) ?: false)
                }
                put("run_id", targetRunId)
                put("phase", resolvedPhase)
                put("role", resolvedRole)
                put("generation", resolvedGen)
                put("token", resolvedToken)
                put("events_jsonl_path", jsonlFile?.absolutePath ?: "")
                put("report_json_path", primaryReportFile?.absolutePath ?: "")
                put("events_count", eventsArr.length())
                put("events", eventsArr)
                put("summary", reportJson ?: JSONObject())
                put("persisted_runs", listPersistedRuns())
            }
        }
    }

    private fun sanitizeId(runId: String): String {
        return runId.replace(Regex("[^a-zA-Z0-9._-]"), "_")
    }

    fun resetForTesting(evidenceDir: File? = null) {
        synchronized(stateLock) {
            evidenceRootDir = evidenceDir
            if (evidenceDir != null && !evidenceDir.exists()) {
                evidenceDir.mkdirs()
            }
            activeTokenCounter.set(1L)
            generationCounter.set(1L)
            eventSeqCounter.set(0L)
            currentRunId = UUID.randomUUID().toString()
            currentPhase = "local_ui"
            currentRole = MainActivity.Role.HCE
            lastPersistenceError = null
            currentRunEvents.clear()
            runEventSeqCounters.clear()
            runTerminalStatus.clear()
        }
    }

    fun simulateProcessRestart(evidenceDir: File? = null) {
        resetForTesting(evidenceDir)
    }
}

