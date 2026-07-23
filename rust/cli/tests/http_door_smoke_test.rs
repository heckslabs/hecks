// Doc-rendering lints allowed as at the crate roots: read as source, never
// rendered by `cargo doc`.
#![allow(clippy::doc_overindented_list_items)]
#![allow(clippy::doc_lazy_continuation)]

//! Ephemeral-port HTTP door smoke — proves over a REAL socket what the
//! socket-free matrix (tests/http_door_gate_test.rs in the lib crate) proves
//! over `route()` directly :
//!   1. the `Authorization: Bearer` header SURVIVES `read_request` (a ghost
//!      bearer is denied on an OPEN door — only possible if the header made
//!      it through header parsing to the stamp) ;
//!   2. the resident server NEVER exits on a denial (a follow-up request on
//!      the same server answers 200) ;
//!   3. `door do posture "governed" end` in the SERVED root's own `.world`
//!      flips the door : a header-less request 403s instead of running as
//!      System.
//! Env hygiene per cold_read_gate_test : the spawned server never inherits
//! the deploy-floor escape or an ambient session identity.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};

const VAULT: &str = r#"Hecks.bluebook "Vault" do
  aggregate "Box" do
    attribute :name, Name
    value_object "Name" do
      attribute :value, String
    end
    command "Open" do
      role "Keeper"
      attribute :name, Name
    end
    query "All" do
      where(name: "x")
    end
  end
end
"#;

const GOVERNED_WORLD: &str = r#"Hecks.world "VaultDeploy" do
  door do
    posture "governed"
  end
end
"#;

/// Kill the spawned serve on drop — no orphaned listeners after a panic.
struct Server(Child);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").expect("bind :0").local_addr().unwrap().port()
}

fn temp_root(tag: &str, governed: bool) -> std::path::PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("hecks_http_door_{}_{}", tag, std::process::id()));
    std::fs::create_dir_all(&dir).expect("mkdir temp root");
    std::fs::write(dir.join("vault.bluebook"), VAULT).expect("write bluebook");
    if governed {
        std::fs::write(dir.join("vault.world"), GOVERNED_WORLD).expect("write world");
    }
    dir
}

fn spawn_serve(root: &std::path::Path, port: u16) -> Server {
    let bin = env!("CARGO_BIN_EXE_storehouse");
    let mut cmd = Command::new(bin);
    cmd.arg("serve").arg(root).arg(port.to_string());
    cmd.env_remove("HECKS_GOVERNANCE_OFF");
    cmd.env_remove("HECKS_SESSION_AUTH_ID");
    cmd.env_remove("HECKS_PRINCIPAL_KIND");
    cmd.stdout(Stdio::null()).stderr(Stdio::null());
    Server(cmd.spawn().expect("spawn storehouse serve"))
}

/// One raw HTTP exchange — retries the connect while the server boots.
fn request(port: u16, raw: &str) -> String {
    for _ in 0..200 {
        if let Ok(mut s) = TcpStream::connect(("127.0.0.1", port)) {
            s.write_all(raw.as_bytes()).expect("write request");
            let mut buf = String::new();
            let _ = s.read_to_string(&mut buf);
            if !buf.is_empty() {
                return buf;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    panic!("server never answered on port {}", port);
}

fn get(port: u16, path: &str, bearer: Option<&str>) -> String {
    let auth = bearer
        .map(|b| format!("Authorization: Bearer {}\r\n", b))
        .unwrap_or_default();
    request(port, &format!(
        "GET {} HTTP/1.1\r\nHost: localhost\r\n{}Connection: close\r\n\r\n",
        path, auth
    ))
}

#[test]
fn open_door_bearer_survives_read_request_and_server_survives_denial() {
    let root = temp_root("open", false);
    let port = free_port();
    let _server = spawn_serve(&root, port);

    // A ghost bearer on an OPEN door is denied — the ONLY way this 403s is
    // the Authorization header surviving read_request into the stamp.
    let denied = get(port, "/domains/Vault/query/all", Some("ghost"));
    assert!(denied.starts_with("HTTP/1.1 403"),
        "ghost bearer must 403 on the open door: {}", denied);

    // Follow-up WITHOUT a header : System admitted — today's behavior — and
    // the same server answering proves a denial never kills the resident door.
    let admitted = get(port, "/domains/Vault/query/all", None);
    assert!(admitted.starts_with("HTTP/1.1 200"),
        "header-less open-door read must stay admitted: {}", admitted);
    assert!(admitted.contains("\"query\":\"All\""),
        "the query resolves: {}", admitted);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn governed_door_fails_closed_without_a_bearer() {
    let root = temp_root("governed", true);
    let port = free_port();
    let _server = spawn_serve(&root, port);

    // The served root's own .world declares `door do posture "governed" end`
    // — a header-less caller stamps as an identity-less agent, fails closed.
    let denied = get(port, "/domains/Vault/query/all", None);
    assert!(denied.starts_with("HTTP/1.1 403"),
        "governed door must fail closed without a bearer: {}", denied);

    // The server stays resident across the denial (health stays open — a
    // liveness probe, not domain state).
    let alive = get(port, "/health", None);
    assert!(alive.starts_with("HTTP/1.1 200"),
        "server must keep serving after the denial: {}", alive);

    let _ = std::fs::remove_dir_all(&root);
}
