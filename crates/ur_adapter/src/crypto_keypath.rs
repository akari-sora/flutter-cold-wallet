use crate::bounded_cbor::BoundedCborValue;
use crate::error::UrError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathComponent {
    pub index: u32,
    pub hardened: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CryptoKeyPath {
    pub components: Vec<PathComponent>,
    pub source_fingerprint: Option<[u8; 4]>,
    pub depth: Option<u32>,
}

impl CryptoKeyPath {
    pub const CBOR_TAG: u64 = 304;

    pub fn from_cbor_value(val: &BoundedCborValue) -> Result<Self, UrError> {
        let map = val.as_map()?;
        let mut components = Vec::new();
        let mut source_fingerprint = None;
        let mut depth = None;

        for (k, v) in map {
            if let BoundedCborValue::Unsigned(k_int) = k {
                match k_int {
                    1 => {
                        // Array of components [idx, hardened, idx, hardened, ...]
                        if let BoundedCborValue::Array(items) = v {
                            if items.len() % 2 != 0 {
                                return Err(UrError::InvalidDerivationPath(
                                    "Path components array must contain even number of elements".into(),
                                ));
                            }
                            for chunk in items.chunks(2) {
                                let index = chunk[0].as_u32()?;
                                let hardened = match &chunk[1] {
                                    BoundedCborValue::Bool(b) => *b,
                                    _ => {
                                        return Err(UrError::InvalidDerivationPath(
                                            "Hardened flag must be boolean".into(),
                                        ))
                                    }
                                };
                                components.push(PathComponent { index, hardened });
                            }
                        }
                    }
                    2 => {
                        let fp = v.as_u32()?;
                        source_fingerprint = Some(fp.to_be_bytes());
                    }
                    3 => {
                        depth = Some(v.as_u32()?);
                    }
                    _ => {}
                }
            }
        }

        if components.is_empty() {
            return Err(UrError::MissingRequiredField("components in CryptoKeypath"));
        }

        Ok(Self {
            components,
            source_fingerprint,
            depth,
        })
    }

    pub fn to_string_path(&self) -> String {
        let mut s = String::from("m");
        for c in &self.components {
            s.push('/');
            s.push_str(&c.index.to_string());
            if c.hardened {
                s.push('\'');
            }
        }
        s
    }

    pub fn from_string_path(
        path_str: &str,
        source_fingerprint: Option<[u8; 4]>,
    ) -> Result<Self, UrError> {
        let clean = path_str.trim();
        let stripped = clean
            .strip_prefix("m/")
            .or_else(|| clean.strip_prefix("M/"))
            .ok_or_else(|| {
                UrError::InvalidDerivationPath(format!(
                    "Derivation path must start with m/: {}",
                    clean
                ))
            })?;

        let mut components = Vec::new();
        for seg in stripped.split('/') {
            let seg = seg.trim();
            if seg.is_empty() {
                return Err(UrError::InvalidDerivationPath(format!(
                    "Empty segment in derivation path: {}",
                    clean
                )));
            }
            let (num_str, hardened) = if let Some(n) = seg.strip_suffix('\'') {
                (n, true)
            } else if let Some(n) = seg.strip_suffix('h').or_else(|| seg.strip_suffix('H')) {
                (n, true)
            } else {
                (seg, false)
            };
            let index = num_str.parse::<u32>().map_err(|_| {
                UrError::InvalidDerivationPath(format!("Invalid path index '{}' in {}", seg, clean))
            })?;
            components.push(PathComponent { index, hardened });
        }

        if components.is_empty() {
            return Err(UrError::MissingRequiredField("components in CryptoKeypath"));
        }

        let depth = Some(components.len() as u32);
        Ok(Self {
            components,
            source_fingerprint,
            depth,
        })
    }
}
