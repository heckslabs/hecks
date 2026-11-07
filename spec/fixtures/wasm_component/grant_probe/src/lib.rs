//! A component that asks the host for a secret and for a URL, and reports the answer or the
//! refusal verbatim.

wit_bindgen::generate!({
    path: "../../../../rust/host/wit",
    world: "grant-probe",
});

use hecks::adapters::{http_out, secrets};

struct GrantProbe;

fn refusal_text(refusal: &secrets::Refusal) -> String {
    match refusal {
        secrets::Refusal::Undeclared(name) => format!("undeclared: {name}"),
        secrets::Refusal::Failed(why) => format!("failed: {why}"),
    }
}

impl Guest for GrantProbe {
    fn read_secret(name: String) -> Result<String, String> {
        match secrets::get(&name) {
            Ok(Some(value)) => Ok(value),
            Ok(None) => Err(format!("unset: {name}")),
            Err(refusal) => Err(refusal_text(&refusal)),
        }
    }

    fn fetch(url: String) -> Result<String, String> {
        let call = http_out::Call {
            method: "GET".to_string(),
            url,
            headers: Vec::new(),
            body: Vec::new(),
            timeout_ms: 2000,
        };
        match http_out::request(&call) {
            Ok(reply) => Ok(format!("{} {}", reply.status, String::from_utf8_lossy(&reply.body))),
            Err(http_out::Refusal::Undeclared(host)) => Err(format!("undeclared: {host}")),
            Err(http_out::Refusal::Failed(why)) => Err(format!("failed: {why}")),
        }
    }
}

export!(GrantProbe);
