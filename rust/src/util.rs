#[cfg(not(target_arch = "wasm32"))]
use std::fs;
#[cfg(not(target_arch = "wasm32"))]
use std::io::Read as IoRead;

pub fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];

    #[cfg(not(target_arch = "wasm32"))]
    {
        if let Ok(mut f) = fs::File::open("/dev/urandom") {
            let _ = f.read_exact(&mut bytes);
        } else {
            let seed = crate::clock::now_duration().as_nanos();
            for (i, b) in bytes.iter_mut().enumerate() {
                *b = ((seed >> (i * 4)) & 0xff) as u8;
            }
        }
    }
    #[cfg(target_arch = "wasm32")]
    {
        if getrandom::getrandom(&mut bytes).is_err() {
            let seed = crate::clock::now_duration().as_nanos();
            for (i, b) in bytes.iter_mut().enumerate() {
                let chunk = (seed >> ((i * 13) % 128)) ^ (seed >> ((i * 7) % 128));
                *b = (chunk & 0xff) as u8;
            }
        }
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_v4_is_well_formed() {
        let id = uuid_v4();
        assert_eq!(id.len(), 36);
        assert_eq!(id.chars().filter(|c| *c == '-').count(), 4);
        assert_eq!(id.as_bytes()[14], b'4');
    }
}

/// Raw-byte SHA-256, hex — the held-era-text INTEGRITY digest. This is
/// deliberately not era naming: era identity hashes the canonical
/// projection and is minted once, Ruby-side only. This is a plain
/// tamper check over bytes.
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}
