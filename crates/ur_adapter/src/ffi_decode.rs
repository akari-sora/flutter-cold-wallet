use crate::fountain::{UrSession, MAX_UR_FRAMES, MAX_UR_SESSION_CHARS};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::{Mutex, OnceLock};

pub const MAX_LIVE_UR_SESSIONS: usize = 16;

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "lowercase", deny_unknown_fields)]
enum Command {
    Start { expected_type: String },
    Receive { session_id: u64, frame: String },
    Close { session_id: u64 },
}

#[derive(Deserialize)]
#[serde(untagged)]
enum DecoderRequest {
    Command(Command),
    Batch(Request),
}

struct DecodeError {
    code: &'static str,
    message: String,
}

impl DecodeError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

struct IncrementalSession {
    expected_type: String,
    session: UrSession,
    // Retain only accepted, distinct frames for bounded rollback after an error.
    // A valid receive feeds the fountain decoder exactly once, without replay.
    accepted_frames: Vec<String>,
}

impl IncrementalSession {
    fn receive(&mut self, frame: &str) -> Result<Value, DecodeError> {
        match self.session.receive(frame) {
            Ok(payload) => {
                let normalized = frame.trim().to_ascii_lowercase();
                if !self.accepted_frames.contains(&normalized) {
                    self.accepted_frames.push(normalized);
                }
                Ok(progress(&self.session, payload))
            }
            Err(error) => {
                // The fountain library may mutate before reporting an error.
                // Rebuild only from earlier accepted frames, never rejected input.
                let mut restored = UrSession::new(&self.expected_type);
                for accepted in &self.accepted_frames {
                    restored.receive(accepted).map_err(|_| {
                        DecodeError::new(
                            "ERR_UR_SESSION_RECOVERY",
                            "UR session recovery failed; start a new session",
                        )
                    })?;
                }
                self.session = restored;
                Err(DecodeError::new("ERR_UR_FRAME", error.to_string()))
            }
        }
    }
}

#[derive(Default)]
struct Sessions {
    last_id: u64,
    live: HashMap<u64, IncrementalSession>,
}

static SESSIONS: OnceLock<Mutex<Sessions>> = OnceLock::new();

fn valid_type(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 80
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn progress(session: &UrSession, payload: Option<Vec<u8>>) -> Value {
    json!({"status": if payload.is_some() { "complete" } else { "incomplete" },
        "payload_hex": payload.map(hex::encode),
        "resolved_fragments": session.resolved_fragments(),
        "total_fragments": session.total_fragments()})
}

fn execute(command: Command) -> Result<Value, DecodeError> {
    let mut sessions = SESSIONS
        .get_or_init(|| Mutex::new(Sessions::default()))
        .lock()
        .map_err(|_| {
            DecodeError::new("ERR_UR_SESSION_UNAVAILABLE", "UR session store unavailable")
        })?;
    match command {
        Command::Start { expected_type } => {
            if !valid_type(&expected_type) {
                return Err(DecodeError::new("ERR_UR_TYPE", "Invalid UR type"));
            }
            if sessions.live.len() >= MAX_LIVE_UR_SESSIONS {
                return Err(DecodeError::new(
                    "ERR_UR_SESSION_LIMIT",
                    "Too many live UR sessions",
                ));
            }
            let id = sessions.last_id.checked_add(1).ok_or_else(|| {
                DecodeError::new("ERR_UR_SESSION_IDS_EXHAUSTED", "UR session IDs exhausted")
            })?;
            sessions.last_id = id;
            sessions.live.insert(
                id,
                IncrementalSession {
                    session: UrSession::new(&expected_type),
                    expected_type,
                    accepted_frames: Vec::new(),
                },
            );
            Ok(json!({"status":"started", "session_id":id}))
        }
        Command::Receive { session_id, frame } => {
            let session = sessions.live.get_mut(&session_id).ok_or_else(|| {
                DecodeError::new(
                    "ERR_UR_SESSION_NOT_FOUND",
                    "UR session not found or expired",
                )
            })?;
            let result = session.receive(&frame);
            if result
                .as_ref()
                .is_ok_and(|value| value["status"] == "complete")
                || result
                    .as_ref()
                    .is_err_and(|error| error.code == "ERR_UR_SESSION_RECOVERY")
            {
                sessions.live.remove(&session_id);
            }
            result
        }
        Command::Close { session_id } => {
            sessions.live.remove(&session_id);
            Ok(json!({"status":"closed", "session_id":session_id}))
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    expected_type: String,
    frames: Vec<String>,
}

pub fn decode_json(input: &str) -> Value {
    let result = (|| -> Result<Value, DecodeError> {
        if input.len() > MAX_UR_SESSION_CHARS + 16_384 {
            return Err(DecodeError::new(
                "ERR_UR_INPUT_LIMIT",
                "UR input exceeds limit",
            ));
        }
        let request = match serde_json::from_str::<DecoderRequest>(input)
            .map_err(|_| DecodeError::new("ERR_UR_REQUEST", "Invalid UR decoder request"))?
        {
            DecoderRequest::Command(command) => return execute(command),
            DecoderRequest::Batch(request) => request,
        };
        if request.expected_type.is_empty()
            || request.expected_type.len() > 80
            || request.frames.is_empty()
            || request.frames.len() > MAX_UR_FRAMES
            || request.frames.iter().map(String::len).sum::<usize>() > MAX_UR_SESSION_CHARS
        {
            return Err(DecodeError::new(
                "ERR_UR_SESSION_LIMIT",
                "UR session exceeds limits",
            ));
        }
        let mut session = UrSession::new(&request.expected_type);
        let mut payload = None;
        for frame in &request.frames {
            payload = session
                .receive(frame)
                .map_err(|e| DecodeError::new("ERR_UR_FRAME", e.to_string()))?;
            if payload.is_some() {
                break;
            }
        }
        Ok(progress(&session, payload))
    })();
    result.unwrap_or_else(
        |error| json!({"status":"error", "error":error.message, "error_code":error.code}),
    )
}

/// C callers provide a valid NUL-terminated input allocation. Reads are bounded.
/// # Safety
/// `input` must reference readable bytes through its NUL terminator.
pub unsafe fn decode_frames_json(input: *const c_char) -> *mut c_char {
    let value = if input.is_null() {
        json!({"status":"error","error":"Null UR input","error_code":"ERR_UR_REQUEST"})
    } else {
        let mut length = 0;
        let limit = MAX_UR_SESSION_CHARS + 16_384;
        while length <= limit && *input.add(length) != 0 {
            length += 1;
        }
        if length > limit {
            json!({"status":"error","error":"UR input exceeds limit","error_code":"ERR_UR_INPUT_LIMIT"})
        } else {
            match std::str::from_utf8(std::slice::from_raw_parts(input.cast::<u8>(), length)) {
                Ok(text) => std::panic::catch_unwind(|| decode_json(text))
                    .unwrap_or_else(|_| json!({"status":"error","error":"UR decoding failed","error_code":"ERR_UR_DECODING"})),
                Err(_) => json!({"status":"error","error":"Invalid UR UTF-8","error_code":"ERR_UR_REQUEST"}),
            }
        }
    };
    CString::new(value.to_string())
        .expect("JSON escapes NUL")
        .into_raw()
}

/// # Safety
/// `ptr` must be a result from `decode_frames_json` and must be freed once.
pub unsafe fn free_json(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
