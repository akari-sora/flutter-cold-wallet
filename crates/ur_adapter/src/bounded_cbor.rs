use crate::error::CborError;
use std::collections::BTreeSet;

pub const MAX_ALLOWED_PAYLOAD: usize = 131_072; // 128 KiB
pub const MAX_ALLOWED_DEPTH: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum BoundedCborValue {
    Unsigned(u64),
    Negative(i128),
    Bytes(Vec<u8>),
    Text(String),
    Array(Vec<BoundedCborValue>),
    Map(Vec<(BoundedCborValue, BoundedCborValue)>),
    Tag(u64, Box<BoundedCborValue>),
    Bool(bool),
    Null,
}

impl BoundedCborValue {
    pub fn as_map(&self) -> Result<&[(BoundedCborValue, BoundedCborValue)], CborError> {
        match self {
            BoundedCborValue::Map(m) => Ok(m),
            BoundedCborValue::Tag(_, inner) => inner.as_map(),
            _ => Err(CborError::TypeMismatch {
                expected: "Map",
                found: "Other",
            }),
        }
    }

    pub fn get_map_value(&self, key: u64) -> Option<&BoundedCborValue> {
        if let Ok(entries) = self.as_map() {
            for (k, v) in entries {
                if let BoundedCborValue::Unsigned(k_int) = k {
                    if *k_int == key {
                        return Some(v);
                    }
                }
            }
        }
        None
    }

    pub fn as_bytes(&self) -> Result<&[u8], CborError> {
        match self {
            BoundedCborValue::Bytes(b) => Ok(b),
            _ => Err(CborError::TypeMismatch {
                expected: "Bytes",
                found: "Other",
            }),
        }
    }

    pub fn as_u64(&self) -> Result<u64, CborError> {
        match self {
            BoundedCborValue::Unsigned(u) => Ok(*u),
            _ => Err(CborError::TypeMismatch {
                expected: "Unsigned",
                found: "Other",
            }),
        }
    }

    pub fn as_u32(&self) -> Result<u32, CborError> {
        u32::try_from(self.as_u64()?)
            .map_err(|_| CborError::Malformed("Unsigned integer exceeds u32".into()))
    }

    // CBOR keys compare by decoded value. Map order is not part of that value.
    fn key_identity(&self) -> Self {
        match self {
            Self::Array(items) => Self::Array(items.iter().map(Self::key_identity).collect()),
            Self::Map(entries) => {
                let mut entries: Vec<_> = entries.iter()
                    .map(|(key, value)| (key.key_identity(), value.key_identity()))
                    .collect();
                entries.sort();
                Self::Map(entries)
            }
            Self::Tag(tag, inner) => Self::Tag(*tag, Box::new(inner.key_identity())),
            _ => self.clone(),
        }
    }

    pub fn as_str(&self) -> Result<&str, CborError> {
        match self {
            BoundedCborValue::Text(s) => Ok(s.as_str()),
            _ => Err(CborError::TypeMismatch {
                expected: "Text",
                found: "Other",
            }),
        }
    }

    pub fn as_array(&self) -> Result<&[BoundedCborValue], CborError> {
        match self {
            BoundedCborValue::Array(a) => Ok(a),
            _ => Err(CborError::TypeMismatch {
                expected: "Array",
                found: "Other",
            }),
        }
    }
}

pub struct BoundedCborParser<'a> {
    buf: &'a [u8],
    offset: usize,
    max_depth: usize,
}

impl<'a> BoundedCborParser<'a> {
    pub fn parse(raw_bytes: &'a [u8]) -> Result<BoundedCborValue, CborError> {
        if raw_bytes.len() > MAX_ALLOWED_PAYLOAD {
            return Err(CborError::PayloadTooLarge(raw_bytes.len()));
        }

        let mut parser = Self {
            buf: raw_bytes,
            offset: 0,
            max_depth: MAX_ALLOWED_DEPTH,
        };

        let root = parser.parse_item(0)?;

        if parser.offset != raw_bytes.len() {
            return Err(CborError::TrailingBytes(raw_bytes.len() - parser.offset));
        }

        Ok(root)
    }

    fn parse_item(&mut self, depth: usize) -> Result<BoundedCborValue, CborError> {
        if depth > self.max_depth {
            return Err(CborError::DepthExceeded(depth));
        }

        if self.offset >= self.buf.len() {
            return Err(CborError::UnexpectedEof);
        }

        let init = self.buf[self.offset];
        self.offset += 1;

        let major = init >> 5;
        let info = init & 0x1f;

        let val = self.read_arg(info)?;

        match major {
            0 => Ok(BoundedCborValue::Unsigned(val)),
            1 => Ok(BoundedCborValue::Negative(-1 - i128::from(val))),
            2 => {
                let len = usize::try_from(val).map_err(|_| CborError::UnexpectedEof)?;
                let end = self.offset.checked_add(len).ok_or(CborError::UnexpectedEof)?;
                if end > self.buf.len() {
                    return Err(CborError::UnexpectedEof);
                }
                let slice = &self.buf[self.offset..end];
                self.offset = end;
                Ok(BoundedCborValue::Bytes(slice.to_vec()))
            }
            3 => {
                let len = usize::try_from(val).map_err(|_| CborError::UnexpectedEof)?;
                let end = self.offset.checked_add(len).ok_or(CborError::UnexpectedEof)?;
                if end > self.buf.len() {
                    return Err(CborError::UnexpectedEof);
                }
                let slice = &self.buf[self.offset..end];
                self.offset = end;
                let s = std::str::from_utf8(slice)
                    .map_err(|e| CborError::Malformed(e.to_string()))?;
                Ok(BoundedCborValue::Text(s.to_string()))
            }
            4 => {
                let count = usize::try_from(val).map_err(|_| CborError::UnexpectedEof)?;
                let mut arr = Vec::with_capacity(count.min(1024));
                for _ in 0..count {
                    arr.push(self.parse_item(depth + 1)?);
                }
                Ok(BoundedCborValue::Array(arr))
            }
            5 => {
                let count = usize::try_from(val).map_err(|_| CborError::UnexpectedEof)?;
                let mut map = Vec::with_capacity(count.min(1024));
                let mut seen_keys = BTreeSet::new();

                for _ in 0..count {
                    let key_start = self.offset;
                    let key = self.parse_item(depth + 1)?;
                    let key_raw = &self.buf[key_start..self.offset];

                    if !seen_keys.insert(key.key_identity()) {
                        return Err(CborError::DuplicateKey(hex::encode(key_raw)));
                    }

                    let value = self.parse_item(depth + 1)?;
                    map.push((key, value));
                }
                Ok(BoundedCborValue::Map(map))
            }
            6 => {
                let tag = val;
                let inner = self.parse_item(depth + 1)?;
                Ok(BoundedCborValue::Tag(tag, Box::new(inner)))
            }
            7 => match info {
                20 => Ok(BoundedCborValue::Bool(false)),
                21 => Ok(BoundedCborValue::Bool(true)),
                22 => Ok(BoundedCborValue::Null),
                _ => Err(CborError::Malformed("Unsupported CBOR simple or floating-point value".into())),
            },
            _ => Err(CborError::Malformed(format!("Unknown major type {}", major))),
        }
    }

    fn read_arg(&mut self, info: u8) -> Result<u64, CborError> {
        if info < 24 {
            Ok(info as u64)
        } else if info == 24 {
            if self.offset >= self.buf.len() {
                return Err(CborError::UnexpectedEof);
            }
            let b = self.buf[self.offset];
            self.offset += 1;
            Ok(b as u64)
        } else if info == 25 {
            if self.offset + 2 > self.buf.len() {
                return Err(CborError::UnexpectedEof);
            }
            let mut arr = [0u8; 2];
            arr.copy_from_slice(&self.buf[self.offset..self.offset + 2]);
            self.offset += 2;
            Ok(u16::from_be_bytes(arr) as u64)
        } else if info == 26 {
            if self.offset + 4 > self.buf.len() {
                return Err(CborError::UnexpectedEof);
            }
            let mut arr = [0u8; 4];
            arr.copy_from_slice(&self.buf[self.offset..self.offset + 4]);
            self.offset += 4;
            Ok(u32::from_be_bytes(arr) as u64)
        } else if info == 27 {
            if self.offset + 8 > self.buf.len() {
                return Err(CborError::UnexpectedEof);
            }
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&self.buf[self.offset..self.offset + 8]);
            self.offset += 8;
            Ok(u64::from_be_bytes(arr))
        } else if info == 31 {
            Err(CborError::IndefiniteLengthRejected)
        } else {
            Err(CborError::Malformed(format!("Reserved additional info {}", info)))
        }
    }
}
