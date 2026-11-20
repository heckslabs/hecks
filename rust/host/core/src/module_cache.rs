//! Wasm modules that ride in the IR (a plugin's or a component's), written once to a cache file
//! named by their SHA-256 after checking the bytes match it, so the runner compiles each path once
//! and a deploy runs exactly the build its IR names.

use base64::Engine as _;
use sha2::{Digest, Sha256};
use std::path::PathBuf;

/// The path of the module `encoded` (base64) carries for `owner`, written on first use. Refuses a
/// module that is not base64 or does not match `sha256`, naming `owner`.
pub fn cached(owner: &str, sha256: &str, encoded: &str) -> Result<PathBuf, String> {
    let path = dir().join(format!("{sha256}.wasm"));
    if path.exists() {
        return Ok(path);
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|e| format!("{owner}'s module is not base64: {e}"))?;
    if hex(&Sha256::digest(&bytes)) != sha256 {
        return Err(format!("{owner}'s module does not match its digest"));
    }
    std::fs::create_dir_all(dir()).map_err(|e| e.to_string())?;
    // Written beside and renamed, so a concurrent reader never compiles a partial module.
    let partial = path.with_extension(format!("{}.partial", std::process::id()));
    std::fs::write(&partial, &bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&partial, &path).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Lower-case hex of `bytes`, as a SHA-256 digest is written in the IR.
pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

/// Where modules are written, one file per digest.
fn dir() -> PathBuf {
    std::env::temp_dir().join("hecks-plugins")
}
