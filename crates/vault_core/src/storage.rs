use aes_gcm::{
    aead::{AeadInPlace, KeyInit},
    Aes256Gcm, Nonce, Tag,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use thiserror::Error;
use zeroize::Zeroizing;

// Version 1 used a custom cipher and is deliberately not migrated implicitly.
pub const CURRENT_STORAGE_SCHEMA_VERSION: u32 = 2;
pub const EXPECTED_BUNDLE_ID: &str = "com.coldwallet.vault";
pub const BACKUP_BUNDLE_ID: &str = "com.coldwallet.vault.backup";
pub const CIPHER_ALG: &str = "AES-256-GCM";
pub const DEFAULT_KDF_ALG: &str = "PBKDF2-HMAC-SHA256";
pub const DEFAULT_KDF_ITERATIONS: u32 = 600_000;
pub const MAX_KDF_ITERATIONS: u32 = 2_000_000;
pub const MAX_ENVELOPE_BYTES: usize = 16 * 1024;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum StorageError {
    #[error("Authentication failed: data has been tampered or key is invalid")]
    AuthenticationFailed,
    #[error("Schema version mismatch: expected {expected}, got {got}")]
    SchemaVersionMismatch { expected: u32, got: u32 },
    #[error("Bundle ID mismatch: expected {expected}, got {got}")]
    BundleIdMismatch { expected: String, got: String },
    #[error("Fingerprint mismatch: expected {expected}, got {got}")]
    FingerprintMismatch { expected: String, got: String },
    #[error("Nonce reuse detected")]
    NonceReuseDetected,
    #[error("Use at least 12 characters, not only digits (maximum 1024 UTF-8 bytes)")]
    WeakPassword,
    #[error("Unsupported or unsafe KDF parameters")]
    InvalidKdfParameters,
    #[error("Vault or backup exceeds the supported size")]
    PayloadTooLarge,
    #[error("A vault already exists at this location; it was not overwritten")]
    AlreadyExists,
    #[error("IO error: {0}")]
    IoError(String),
    #[error("Serialization error: {0}")]
    SerializationError(String),
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EncryptedVaultEnvelope {
    pub schema_version: u32,
    pub cipher_alg: String,
    pub bundle_id: String,
    pub master_fingerprint: [u8; 4],
    pub nonce: [u8; 12],
    pub ciphertext: Vec<u8>,
    pub auth_tag: [u8; 16],
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PasswordProtectedVaultEnvelope {
    pub schema_version: u32,
    pub kdf_alg: String,
    pub kdf_iterations: u32,
    pub kdf_salt: [u8; 16],
    pub has_passphrase_hint: bool,
    pub envelope: EncryptedVaultEnvelope,
}

fn io_error(error: std::io::Error) -> StorageError {
    if error.kind() == std::io::ErrorKind::AlreadyExists {
        StorageError::AlreadyExists
    } else {
        StorageError::IoError(error.to_string())
    }
}

fn check_version(version: u32) -> Result<(), StorageError> {
    if version != CURRENT_STORAGE_SCHEMA_VERSION {
        return Err(StorageError::SchemaVersionMismatch {
            expected: CURRENT_STORAGE_SCHEMA_VERSION,
            got: version,
        });
    }
    Ok(())
}

pub fn validate_password(password: &str) -> Result<(), StorageError> {
    let trimmed = password.trim();
    if trimmed.chars().count() < 12
        || password.len() > 1024
        || trimmed.chars().all(char::is_numeric)
    {
        return Err(StorageError::WeakPassword);
    }
    Ok(())
}

pub fn build_aad(schema_version: u32, bundle_id: &str, fingerprint: &[u8; 4]) -> Vec<u8> {
    let mut aad = Vec::new();
    aad.extend_from_slice(&schema_version.to_be_bytes());
    aad.extend_from_slice(CIPHER_ALG.as_bytes());
    aad.extend_from_slice(&(bundle_id.len() as u64).to_be_bytes());
    aad.extend_from_slice(bundle_id.as_bytes());
    aad.extend_from_slice(fingerprint);
    aad
}

fn protected_aad(protected: &PasswordProtectedVaultEnvelope) -> Vec<u8> {
    let mut aad = build_aad(
        protected.envelope.schema_version,
        &protected.envelope.bundle_id,
        &protected.envelope.master_fingerprint,
    );
    aad.extend_from_slice(&protected.schema_version.to_be_bytes());
    aad.extend_from_slice(&(protected.kdf_alg.len() as u64).to_be_bytes());
    aad.extend_from_slice(protected.kdf_alg.as_bytes());
    aad.extend_from_slice(&protected.kdf_iterations.to_be_bytes());
    aad.extend_from_slice(&protected.kdf_salt);
    aad.push(u8::from(protected.has_passphrase_hint));
    aad
}

fn validate_envelope(
    envelope: &EncryptedVaultEnvelope,
    expected_bundle_id: &str,
    expected_fingerprint: Option<[u8; 4]>,
) -> Result<(), StorageError> {
    check_version(envelope.schema_version)?;
    if envelope.cipher_alg != CIPHER_ALG || envelope.ciphertext.len() != 64 {
        return Err(StorageError::AuthenticationFailed);
    }
    if envelope.bundle_id.len() > 128 {
        return Err(StorageError::PayloadTooLarge);
    }
    if envelope.bundle_id != expected_bundle_id {
        return Err(StorageError::BundleIdMismatch {
            expected: expected_bundle_id.to_owned(),
            got: envelope.bundle_id.clone(),
        });
    }
    if let Some(fingerprint) = expected_fingerprint {
        if envelope.master_fingerprint != fingerprint {
            return Err(StorageError::FingerprintMismatch {
                expected: hex::encode(fingerprint),
                got: hex::encode(envelope.master_fingerprint),
            });
        }
    }
    Ok(())
}

fn validate_protected(protected: &PasswordProtectedVaultEnvelope) -> Result<(), StorageError> {
    check_version(protected.schema_version)?;
    validate_envelope(&protected.envelope, &protected.envelope.bundle_id, None)?;
    if protected.kdf_alg != DEFAULT_KDF_ALG
        || !(DEFAULT_KDF_ITERATIONS..=MAX_KDF_ITERATIONS).contains(&protected.kdf_iterations)
    {
        return Err(StorageError::InvalidKdfParameters);
    }
    Ok(())
}

fn seal(dek: &[u8; 32], seed: &[u8; 64], nonce: &[u8; 12], aad: &[u8]) -> (Vec<u8>, [u8; 16]) {
    let cipher = Aes256Gcm::new(dek.into());
    let mut ciphertext = Zeroizing::new(seed.to_vec());
    // A fixed 64-byte plaintext is strictly below the AES-GCM message bound.
    let tag = cipher
        .encrypt_in_place_detached(&Nonce::from(*nonce), aad, &mut ciphertext)
        .expect("fixed-size seed is within AES-GCM limits");
    (ciphertext.to_vec(), tag.into())
}

fn open(
    dek: &[u8; 32],
    envelope: &EncryptedVaultEnvelope,
    aad: &[u8],
) -> Result<[u8; 64], StorageError> {
    let cipher = Aes256Gcm::new(dek.into());
    let mut plaintext = Zeroizing::new(envelope.ciphertext.clone());
    cipher
        .decrypt_in_place_detached(
            &Nonce::from(envelope.nonce),
            aad,
            &mut plaintext,
            &Tag::from(envelope.auth_tag),
        )
        .map_err(|_| StorageError::AuthenticationFailed)?;
    plaintext
        .as_slice()
        .try_into()
        .map_err(|_| StorageError::AuthenticationFailed)
}

/// Low-level DEK API. The caller must provide a fresh nonce for every encryption.
/// Password-based production storage generates its own nonce using the OS CSPRNG.
pub fn encrypt_seed(
    dek: &[u8; 32],
    seed: &[u8; 64],
    master_fingerprint: [u8; 4],
    nonce: [u8; 12],
    bundle_id: &str,
) -> EncryptedVaultEnvelope {
    let aad = build_aad(
        CURRENT_STORAGE_SCHEMA_VERSION,
        bundle_id,
        &master_fingerprint,
    );
    let (ciphertext, auth_tag) = seal(dek, seed, &nonce, &aad);
    EncryptedVaultEnvelope {
        schema_version: CURRENT_STORAGE_SCHEMA_VERSION,
        cipher_alg: CIPHER_ALG.to_owned(),
        bundle_id: bundle_id.to_owned(),
        master_fingerprint,
        nonce,
        ciphertext,
        auth_tag,
    }
}

pub fn decrypt_seed(
    dek: &[u8; 32],
    envelope: &EncryptedVaultEnvelope,
    expected_bundle_id: &str,
    expected_fingerprint: Option<[u8; 4]>,
) -> Result<[u8; 64], StorageError> {
    validate_envelope(envelope, expected_bundle_id, expected_fingerprint)?;
    open(
        dek,
        envelope,
        &build_aad(
            envelope.schema_version,
            &envelope.bundle_id,
            &envelope.master_fingerprint,
        ),
    )
}

pub fn derive_dek_pbkdf2(
    password: &str,
    salt: &[u8; 16],
    iterations: u32,
    bundle_id: &str,
) -> Result<[u8; 32], StorageError> {
    validate_password(password)?;
    if !(DEFAULT_KDF_ITERATIONS..=MAX_KDF_ITERATIONS).contains(&iterations) {
        return Err(StorageError::InvalidKdfParameters);
    }
    if bundle_id.len() > 128 {
        return Err(StorageError::PayloadTooLarge);
    }
    let mut context_salt = Vec::with_capacity(16 + bundle_id.len());
    context_salt.extend_from_slice(salt);
    context_salt.extend_from_slice(bundle_id.as_bytes());
    let mut dek = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password.as_bytes(), &context_salt, iterations, &mut dek);
    Ok(dek)
}

pub fn encrypt_seed_with_password(
    password: &str,
    seed: &[u8; 64],
    master_fingerprint: [u8; 4],
    bundle_id: &str,
    has_passphrase_hint: bool,
) -> Result<PasswordProtectedVaultEnvelope, StorageError> {
    validate_password(password)?;
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut salt).map_err(|e| StorageError::IoError(format!("CSPRNG error: {e}")))?;
    getrandom::fill(&mut nonce).map_err(|e| StorageError::IoError(format!("CSPRNG error: {e}")))?;
    let dek = Zeroizing::new(derive_dek_pbkdf2(
        password,
        &salt,
        DEFAULT_KDF_ITERATIONS,
        bundle_id,
    )?);
    let mut protected = PasswordProtectedVaultEnvelope {
        schema_version: CURRENT_STORAGE_SCHEMA_VERSION,
        kdf_alg: DEFAULT_KDF_ALG.to_owned(),
        kdf_iterations: DEFAULT_KDF_ITERATIONS,
        kdf_salt: salt,
        has_passphrase_hint,
        envelope: EncryptedVaultEnvelope {
            schema_version: CURRENT_STORAGE_SCHEMA_VERSION,
            cipher_alg: CIPHER_ALG.to_owned(),
            bundle_id: bundle_id.to_owned(),
            master_fingerprint,
            nonce,
            ciphertext: Vec::new(),
            auth_tag: [0; 16],
        },
    };
    let (ciphertext, auth_tag) = seal(&dek, seed, &nonce, &protected_aad(&protected));
    protected.envelope.ciphertext = ciphertext;
    protected.envelope.auth_tag = auth_tag;
    Ok(protected)
}

pub fn decrypt_seed_with_password(
    password: &str,
    protected: &PasswordProtectedVaultEnvelope,
    expected_bundle_id: &str,
    expected_fingerprint: Option<[u8; 4]>,
) -> Result<[u8; 64], StorageError> {
    validate_protected(protected)?;
    validate_envelope(
        &protected.envelope,
        expected_bundle_id,
        expected_fingerprint,
    )?;
    let dek = Zeroizing::new(derive_dek_pbkdf2(
        password,
        &protected.kdf_salt,
        protected.kdf_iterations,
        expected_bundle_id,
    )?);
    open(&dek, &protected.envelope, &protected_aad(protected))
}

struct TemporaryFile(PathBuf);
impl Drop for TemporaryFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[cfg(not(target_os = "android"))]
fn publish_new_file(temporary: &Path, destination: &Path) -> std::io::Result<()> {
    std::fs::hard_link(temporary, destination)
}

#[cfg(target_os = "android")]
fn publish_new_file(temporary: &Path, destination: &Path) -> std::io::Result<()> {
    use std::ffi::CString;
    use std::os::raw::{c_int, c_long, c_uint};
    use std::os::unix::ffi::OsStrExt;

    // Android app SELinux domains forbid hard links to app_data_file. Use the
    // kernel's atomic no-clobber rename instead. Calling syscall avoids a libc
    // renameat2 symbol dependency (that wrapper was introduced at Android API 30).
    // Numbers and flag are from the NDK's asm-generic/unistd.h, x86_64/unistd_64.h
    // and stdio.h. Both packaged Android ABIs have supported this kernel ABI
    // since before our minimum Android version.
    #[cfg(target_arch = "aarch64")]
    const RENAMEAT2: c_long = 276;
    #[cfg(target_arch = "x86_64")]
    const RENAMEAT2: c_long = 316;
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    compile_error!("Vault atomic publication supports the packaged arm64 and x86_64 Android ABIs");
    const AT_FDCWD: c_int = -100;
    const RENAME_NOREPLACE: c_uint = 1;
    unsafe extern "C" {
        fn syscall(number: c_long, ...) -> c_long;
    }
    let source = CString::new(temporary.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let target = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // SAFETY: both NUL-terminated path allocations remain valid throughout the
    // syscall; the ABI constants and promoted varargs match renameat2(2).
    let result = unsafe {
        syscall(
            RENAMEAT2,
            AT_FDCWD,
            source.as_ptr(),
            AT_FDCWD,
            target.as_ptr(),
            RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn write_new_atomic(path: &Path, bytes: &[u8]) -> Result<(), StorageError> {
    if bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(StorageError::PayloadTooLarge);
    }
    if path.symlink_metadata().is_ok() {
        return Err(StorageError::AlreadyExists);
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).map_err(io_error)?;
    let mut random = [0u8; 16];
    getrandom::fill(&mut random)
        .map_err(|e| StorageError::IoError(format!("CSPRNG error: {e}")))?;
    let temporary_path = parent.join(format!(".vault-{}.tmp", hex::encode(random)));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary_path).map_err(io_error)?;
    // Own cleanup only after create_new succeeds; never remove a colliding file.
    let temporary = TemporaryFile(temporary_path);
    file.write_all(bytes).map_err(io_error)?;
    file.sync_all().map_err(io_error)?;
    drop(file);
    // Publish a complete, synced same-directory inode, atomically refusing any
    // existing destination. Android uses renameat2(RENAME_NOREPLACE) because its
    // application SELinux policy forbids hard links. Never use replacing rename.
    publish_new_file(&temporary.0, path).map_err(io_error)?;
    #[cfg(unix)]
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(io_error)?;
    Ok(())
}

fn read_bounded(path: &Path) -> Result<Vec<u8>, StorageError> {
    let file = File::open(path).map_err(io_error)?;
    if file.metadata().map_err(io_error)?.len() > MAX_ENVELOPE_BYTES as u64 {
        return Err(StorageError::PayloadTooLarge);
    }
    let mut content = Vec::new();
    file.take(MAX_ENVELOPE_BYTES as u64 + 1)
        .read_to_end(&mut content)
        .map_err(io_error)?;
    if content.len() > MAX_ENVELOPE_BYTES {
        return Err(StorageError::PayloadTooLarge);
    }
    Ok(content)
}

fn parse_envelope<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, StorageError> {
    if bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(StorageError::PayloadTooLarge);
    }
    // Inspect the version before parsing the cipher's fields so old schemas are
    // reported explicitly rather than interpreted as this cipher format.
    let value: serde_json::Value = serde_json::from_slice(bytes)
        .map_err(|e| StorageError::SerializationError(e.to_string()))?;
    let version = value
        .get("schema_version")
        .and_then(serde_json::Value::as_u64)
        .and_then(|v| u32::try_from(v).ok())
        .ok_or_else(|| {
            StorageError::SerializationError("Missing or invalid schema version".to_owned())
        })?;
    check_version(version)?;
    serde_json::from_value(value).map_err(|e| StorageError::SerializationError(e.to_string()))
}

pub fn save_envelope_atomic(
    path: &Path,
    envelope: &EncryptedVaultEnvelope,
) -> Result<(), StorageError> {
    validate_envelope(envelope, &envelope.bundle_id, None)?;
    let json = serde_json::to_vec(envelope)
        .map_err(|e| StorageError::SerializationError(e.to_string()))?;
    write_new_atomic(path, &json)
}

pub fn load_envelope(path: &Path) -> Result<EncryptedVaultEnvelope, StorageError> {
    let envelope: EncryptedVaultEnvelope = parse_envelope(&read_bounded(path)?)?;
    validate_envelope(&envelope, &envelope.bundle_id, None)?;
    Ok(envelope)
}

pub fn save_new_protected_envelope_atomic(
    path: &Path,
    protected: &PasswordProtectedVaultEnvelope,
) -> Result<(), StorageError> {
    validate_protected(protected)?;
    let json = serde_json::to_vec(protected)
        .map_err(|e| StorageError::SerializationError(e.to_string()))?;
    write_new_atomic(path, &json)
}

/// Compatibility entry point; saving is intentionally create-only.
pub fn save_protected_envelope_atomic(
    path: &Path,
    protected: &PasswordProtectedVaultEnvelope,
) -> Result<(), StorageError> {
    save_new_protected_envelope_atomic(path, protected)
}

pub fn load_protected_envelope(
    path: &Path,
) -> Result<PasswordProtectedVaultEnvelope, StorageError> {
    let protected: PasswordProtectedVaultEnvelope = parse_envelope(&read_bounded(path)?)?;
    validate_protected(&protected)?;
    Ok(protected)
}

pub fn export_encrypted_backup_json(
    password: &str,
    seed: &[u8; 64],
    master_fingerprint: [u8; 4],
    has_passphrase_hint: bool,
) -> Result<String, StorageError> {
    let envelope = encrypt_seed_with_password(
        password,
        seed,
        master_fingerprint,
        BACKUP_BUNDLE_ID,
        has_passphrase_hint,
    )?;
    serde_json::to_string_pretty(&envelope)
        .map_err(|e| StorageError::SerializationError(e.to_string()))
}

pub fn import_encrypted_backup_json(
    password: &str,
    backup_json: &str,
) -> Result<([u8; 64], [u8; 4], bool), StorageError> {
    let protected: PasswordProtectedVaultEnvelope = parse_envelope(backup_json.as_bytes())?;
    let seed = decrypt_seed_with_password(password, &protected, BACKUP_BUNDLE_ID, None)?;
    Ok((
        seed,
        protected.envelope.master_fingerprint,
        protected.has_passphrase_hint,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_storage_rejects_weak_password_and_unbounded_kdf() {
        for password in ["1234", "1234567890123456", "short"] {
            assert!(derive_dek_pbkdf2(password, &[1; 16], 600_000, EXPECTED_BUNDLE_ID).is_err());
        }
        for iterations in [0, 15_000, 599_999, 2_000_001] {
            assert!(derive_dek_pbkdf2(
                "CorrectHorse#2026",
                &[1; 16],
                iterations,
                EXPECTED_BUNDLE_ID
            )
            .is_err());
        }
    }

    #[test]
    fn test_storage_atomic_write_never_overwrites_existing_or_partial_file() {
        let path =
            std::env::temp_dir().join(format!("vault_no_clobber_{}.json", std::process::id()));
        let original = b"{ partial or unsupported existing vault";
        std::fs::write(&path, original).unwrap();
        let envelope = encrypt_seed(&[1; 32], &[2; 64], [3; 4], [4; 12], EXPECTED_BUNDLE_ID);
        assert!(save_envelope_atomic(&path, &envelope).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn test_storage_authenticates_all_password_metadata() {
        let protected = encrypt_seed_with_password(
            "CorrectHorse#2026",
            &[7; 64],
            [8; 4],
            BACKUP_BUNDLE_ID,
            true,
        )
        .unwrap();
        for field in ["hint", "salt", "iterations", "fingerprint", "nonce"] {
            let mut tampered = protected.clone();
            match field {
                "hint" => tampered.has_passphrase_hint = false,
                "salt" => tampered.kdf_salt[0] ^= 1,
                "iterations" => tampered.kdf_iterations += 1,
                "fingerprint" => tampered.envelope.master_fingerprint[0] ^= 1,
                "nonce" => tampered.envelope.nonce[0] ^= 1,
                _ => unreachable!(),
            }
            assert_eq!(
                decrypt_seed_with_password("CorrectHorse#2026", &tampered, BACKUP_BUNDLE_ID, None),
                Err(StorageError::AuthenticationFailed),
                "{field}"
            );
        }
        for iterations in [599_999, MAX_KDF_ITERATIONS + 1, u32::MAX] {
            let mut tampered = protected.clone();
            tampered.kdf_iterations = iterations;
            assert_eq!(
                decrypt_seed_with_password("CorrectHorse#2026", &tampered, BACKUP_BUNDLE_ID, None),
                Err(StorageError::InvalidKdfParameters)
            );
        }
        let mut tampered = protected.clone();
        tampered.kdf_alg = "other-kdf".to_owned();
        assert_eq!(
            decrypt_seed_with_password("CorrectHorse#2026", &tampered, BACKUP_BUNDLE_ID, None),
            Err(StorageError::InvalidKdfParameters)
        );
        tampered = protected.clone();
        tampered.envelope.cipher_alg = "other-cipher".to_owned();
        assert_eq!(
            decrypt_seed_with_password("CorrectHorse#2026", &tampered, BACKUP_BUNDLE_ID, None),
            Err(StorageError::AuthenticationFailed)
        );
    }

    #[test]
    fn test_storage_rejects_oversized_and_legacy_imports_before_kdf() {
        assert_eq!(
            import_encrypted_backup_json("CorrectHorse#2026", &"x".repeat(MAX_ENVELOPE_BYTES + 1)),
            Err(StorageError::PayloadTooLarge)
        );
        assert_eq!(
            import_encrypted_backup_json("CorrectHorse#2026", r#"{"schema_version":1}"#),
            Err(StorageError::SchemaVersionMismatch {
                expected: 2,
                got: 1
            })
        );
        let path =
            std::env::temp_dir().join(format!("vault_oversized_{}.json", std::process::id()));
        std::fs::write(&path, vec![0; MAX_ENVELOPE_BYTES + 1]).unwrap();
        assert_eq!(
            load_protected_envelope(&path),
            Err(StorageError::PayloadTooLarge)
        );
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn test_storage_atomic_creation_has_one_winner_and_ignores_incomplete_temporary() {
        let path =
            std::env::temp_dir().join(format!("vault_atomic_race_{}.json", std::process::id()));
        let incomplete = path.with_extension("tmp");
        std::fs::write(&incomplete, b"interrupted partial write").unwrap();
        assert!(load_envelope(&path).is_err());
        let envelope = encrypt_seed(&[1; 32], &[2; 64], [3; 4], [4; 12], EXPECTED_BUNDLE_ID);
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let threads: Vec<_> = (0..8)
            .map(|_| {
                let path = path.clone();
                let envelope = envelope.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    save_envelope_atomic(&path, &envelope)
                })
            })
            .collect();
        let results: Vec<_> = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| **result == Err(StorageError::AlreadyExists))
                .count(),
            7
        );
        assert_eq!(load_envelope(&path).unwrap(), envelope);
        assert_eq!(
            std::fs::read(&incomplete).unwrap(),
            b"interrupted partial write"
        );
        std::fs::remove_file(path).unwrap();
        std::fs::remove_file(incomplete).unwrap();
    }

    #[test]
    fn test_store_02_aead_tamper_and_aad_binding() {
        let dek = [0x42u8; 32];
        let seed = [0xa5u8; 64];
        let fp = [0x73, 0xc5, 0xda, 0x0a];
        let nonce = [0x11u8; 12];
        let bundle_id = "com.coldwallet.vault";

        // 1. Valid encryption & decryption
        let envelope = encrypt_seed(&dek, &seed, fp, nonce, bundle_id);
        let decrypted = decrypt_seed(&dek, &envelope, bundle_id, Some(fp)).unwrap();
        assert_eq!(decrypted, seed);

        // 2. Tampered ciphertext bit-flip MUST fail authentication
        let mut tampered = envelope.clone();
        tampered.ciphertext[5] ^= 0x01;
        let err = decrypt_seed(&dek, &tampered, bundle_id, Some(fp)).unwrap_err();
        assert_eq!(err, StorageError::AuthenticationFailed);

        // 3. Tampered auth_tag MUST fail authentication
        let mut tampered_tag = envelope.clone();
        tampered_tag.auth_tag[0] ^= 0x80;
        let err_tag = decrypt_seed(&dek, &tampered_tag, bundle_id, Some(fp)).unwrap_err();
        assert_eq!(err_tag, StorageError::AuthenticationFailed);

        // 4. Bundle ID mismatch MUST be rejected
        let err_bundle = decrypt_seed(&dek, &envelope, "com.malicious.app", Some(fp)).unwrap_err();
        assert!(matches!(err_bundle, StorageError::BundleIdMismatch { .. }));

        // 5. Wrong master fingerprint MUST be rejected
        let err_fp =
            decrypt_seed(&dek, &envelope, bundle_id, Some([0x00, 0x00, 0x00, 0x00])).unwrap_err();
        assert!(matches!(err_fp, StorageError::FingerprintMismatch { .. }));

        // 6. Schema version mismatch MUST be rejected
        let mut tampered_schema = envelope.clone();
        tampered_schema.schema_version = 999;
        let err_ver = decrypt_seed(&dek, &tampered_schema, bundle_id, Some(fp)).unwrap_err();
        assert!(matches!(
            err_ver,
            StorageError::SchemaVersionMismatch { .. }
        ));
    }

    #[test]
    fn test_store_03_atomic_write_and_recovery() {
        let temp_dir = std::env::temp_dir();
        let target_path = temp_dir.join(format!("test_vault_storage_{}.json", std::process::id()));

        let dek = [0x55u8; 32];
        let seed = [0x7eu8; 64];
        let fp = [0x12, 0x34, 0x56, 0x78];
        let nonce = [0x99u8; 12];
        let bundle_id = "com.coldwallet.vault";

        let envelope = encrypt_seed(&dek, &seed, fp, nonce, bundle_id);
        save_envelope_atomic(&target_path, &envelope).expect("Atomic write should succeed");

        // Verify file exists and tmp does not remain
        assert!(target_path.exists());
        let tmp_path = target_path.with_extension("tmp");
        assert!(!tmp_path.exists());

        // Load and decrypt
        let loaded = load_envelope(&target_path).expect("Load should succeed");
        assert_eq!(loaded, envelope);
        let recovered = decrypt_seed(&dek, &loaded, bundle_id, Some(fp)).unwrap();
        assert_eq!(recovered, seed);

        // Cleanup
        let _ = std::fs::remove_file(target_path);
    }

    #[test]
    fn test_store_04_password_protected_backup_and_adversarial_restore() {
        let seed = [0x3cu8; 64];
        let fp = [0x73, 0xc5, 0xda, 0x0a];
        let backup_json = export_encrypted_backup_json("CorrectHorse#2026", &seed, fp, true)
            .expect("Backup export should succeed");

        // 1. Correct password succeeds
        let (rec_seed, rec_fp, hint) =
            import_encrypted_backup_json("CorrectHorse#2026", &backup_json).unwrap();
        assert_eq!(rec_seed, seed);
        assert_eq!(rec_fp, fp);
        assert!(hint);

        // 2. Wrong password fails
        let err_wrong_pw =
            import_encrypted_backup_json("WrongPassword#2026", &backup_json).unwrap_err();
        assert_eq!(err_wrong_pw, StorageError::AuthenticationFailed);

        // 3. Tampered byte in ciphertext fails
        let mut parsed: PasswordProtectedVaultEnvelope =
            serde_json::from_str(&backup_json).unwrap();
        parsed.envelope.ciphertext[0] ^= 0x01;
        let tampered_json = serde_json::to_string(&parsed).unwrap();
        let err_tamper =
            import_encrypted_backup_json("CorrectHorse#2026", &tampered_json).unwrap_err();
        assert_eq!(err_tamper, StorageError::AuthenticationFailed);

        // 4. Truncated file fails
        let truncated = &backup_json[..backup_json.len() / 2];
        let err_trunc = import_encrypted_backup_json("CorrectHorse#2026", truncated).unwrap_err();
        assert!(matches!(err_trunc, StorageError::SerializationError(_)));

        // 5. Unsupported version fails
        let mut bad_ver: PasswordProtectedVaultEnvelope =
            serde_json::from_str(&backup_json).unwrap();
        bad_ver.schema_version = 42;
        let bad_ver_json = serde_json::to_string(&bad_ver).unwrap();
        let err_ver = import_encrypted_backup_json("CorrectHorse#2026", &bad_ver_json).unwrap_err();
        assert!(matches!(
            err_ver,
            StorageError::SchemaVersionMismatch { .. }
        ));
    }
}
