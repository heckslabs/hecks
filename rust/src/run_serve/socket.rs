//! run_serve::socket — the unix-domain-socket transport for the warm
//! serve loop. The daemon that survives a Claude restart.
//!
//! [antibody-exempt: rust/src/run_serve/socket.rs — kernel-floor runtime
//!  perf transport. Binds a unix domain socket and answers warm
//!  dispatches over it so the resident runtime lives as an overmind
//!  DAEMON (body) independent of Claude. A Claude restart rebuilds only
//!  the MCP membrane ; this warm daemon persists. A bluebook can't
//!  describe its own socket accept loop ; the dispatch BODY is the
//!  shared bluebook contract in mod.rs (`handle_request`, byte-identical
//!  to the one-shot CLI path).]
//!
//! ## why a socket, not stdin/stdout
//!
//! The stdio transport (`stdio.rs`) is spawned by whoever owns the
//! pipe — the MCP server, which Claude Code starts. So the warm child
//! dies on every Claude restart and re-pays the ~660ms boot. Binding a
//! unix socket and running as an overmind daemon decouples the warm
//! process lifetime from Claude : the MCP becomes a thin CLIENT that
//! connects per dispatch ; the daemon stays warm across restarts.
//!
//! ## socket path — deterministic per-root derivation
//!
//! The daemon and the MCP client must agree on the address WITHOUT
//! coordinating. Both derive it from the canonical aggregates-root path :
//!
//!   `~/.config/miette/sockets/<hash>-<basename>.sock`
//!
//! where `<hash>` is a stable `DefaultHasher` digest of the canonicalised
//! root (fixed-seed → identical across processes and restarts) and
//! `<basename>` is the root's directory name for human debuggability.
//! "One daemon per root" then scales naturally : add a Procfile entry
//! for another root tomorrow and the same MCP picks it up with zero code
//! change (it just finds a socket where before it found none).
//!
//! ## concurrency — single accept-and-process loop
//!
//! `Runtime::dispatch` takes `&mut self`, so dispatches must serialize.
//! We do NOT reach for a mutex/threads : one thread, blocking `accept`,
//! handle one connection to completion, loop. Concurrent clients queue
//! at `accept` — correct given the shared mutable runtime, and identical
//! in spirit to the stdio loop (one request in flight at a time).
//!
//! ## protocol — same sentinel lines as stdio
//!
//! Per connection : read ONE request line, hand it to `handle_request`,
//! write the ONE sentinel-prefixed result line back, flush, close. The
//! resident runtime's free-form `println!` adapter/log output goes to
//! the daemon's OWN stdout/stderr (overmind's log), never the socket —
//! so the socket stream carries only the authoritative result line.

use super::{handle_request, LegacyLlmHook};
use crate::runtime::Runtime;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

/// Directory under the user's home where per-root sockets live.
/// Mirrors the `~/.config/miette/` convention the body already uses.
fn sockets_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    Path::new(&home).join(".config").join("miette").join("sockets")
}

/// Derive the deterministic socket path for an aggregates root. Both
/// the daemon (on bind) and the MCP client (on connect) call this with
/// the SAME root and must compute the SAME path — so it canonicalises
/// first (falling back to the raw path if the dir doesn't exist yet)
/// and hashes with a fixed-seed `DefaultHasher` (stable across
/// processes and restarts, unlike `RandomState`).
pub fn sock_path_for_root(root: &str) -> PathBuf {
    let canon = std::fs::canonicalize(root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| root.trim_end_matches('/').to_string());
    let mut hasher = DefaultHasher::new();
    canon.hash(&mut hasher);
    let hash = hasher.finish();
    let basename = Path::new(&canon)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "root".to_string());
    sockets_dir().join(format!("{:016x}-{}.sock", hash, basename))
}

/// Run the resident serve loop against an already-booted runtime over a
/// unix domain socket bound at `sock_path` (default :
/// `sock_path_for_root(<the booted root>)`). Single accept-and-process
/// loop ; never returns under normal operation (exits the process on a
/// fatal bind error). Returns a non-zero code only on bind failure.
pub fn run(rt: &mut Runtime, sock_path: &Path, legacy_llm: Option<&LegacyLlmHook>) -> i32 {
    if let Some(parent) = sock_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("[serve-socket] cannot create {}: {}", parent.display(), e);
            return 1;
        }
    }
    // A stale socket file from a prior daemon would make bind fail with
    // EADDRINUSE even though nobody is listening. Remove it first ; if a
    // live daemon is actually bound, the connect-based liveness check in
    // the daemon launcher (or overmind's single-instance supervision)
    // is what prevents two daemons — not this unlink.
    let _ = std::fs::remove_file(sock_path);

    let listener = match UnixListener::bind(sock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[serve-socket] bind {} failed: {}", sock_path.display(), e);
            return 1;
        }
    };
    eprintln!("[serve-socket] warm daemon listening on {}", sock_path.display());

    for stream in listener.incoming() {
        match stream {
            Ok(conn) => handle_conn(rt, conn, legacy_llm),
            Err(e) => {
                eprintln!("[serve-socket] accept error: {}", e);
                // Transient accept error — keep serving.
            }
        }
    }
    0
}

/// Handle ONE connection to completion : read one request line,
/// dispatch via the shared `handle_request`, write the one
/// sentinel-prefixed result line back. Errors are logged to the
/// daemon's stderr and the connection is dropped — never panics, so one
/// bad client can't take the warm runtime down.
fn handle_conn(rt: &mut Runtime, conn: UnixStream, legacy_llm: Option<&LegacyLlmHook>) {
    let mut writer = match conn.try_clone() {
        Ok(w) => w,
        Err(e) => {
            eprintln!("[serve-socket] clone stream: {}", e);
            return;
        }
    };
    let mut reader = BufReader::new(conn);
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) => return, // client closed without a request
        Ok(_) => {}
        Err(e) => {
            eprintln!("[serve-socket] read error: {}", e);
            return;
        }
    }
    let req = line.trim();
    if req.is_empty() { return; }

    let result_line = handle_request(rt, req, legacy_llm);
    if let Err(e) = writeln!(writer, "{}", result_line) {
        eprintln!("[serve-socket] write error: {}", e);
        return;
    }
    let _ = writer.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sock_path_is_deterministic_for_same_root() {
        let a = sock_path_for_root("/tmp");
        let b = sock_path_for_root("/tmp");
        assert_eq!(a, b);
    }

    #[test]
    fn sock_path_differs_by_root() {
        let a = sock_path_for_root("/tmp");
        let b = sock_path_for_root("/usr");
        assert_ne!(a, b);
    }

    #[test]
    fn sock_path_carries_basename_and_sock_suffix() {
        let p = sock_path_for_root("/tmp");
        let name = p.file_name().unwrap().to_string_lossy();
        assert!(name.ends_with("-tmp.sock"), "got {name}");
    }
}
