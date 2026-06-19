//! send-message (Rust) — a standalone, COMPILED out-of-process messaging adapter :
//! send a message to a running agent by id, BLOCK until it replies, print the reply.
//!
//! This makes Tools::AgentTool.SendMessage REAL (it was a canned "agent resumed"
//! stub — the runtime never had an agent-resume API). Per i708, agents coordinate
//! through storehouse : there is no direct channel. So this routes through the
//! AgentInbox blackboard (framework/agent_inbox/agent_inbox.bluebook) :
//!
//!   1. mint a correlation id, dispatch AgentInbox::AgentMessage.Send id=<cid>
//!      agent_id=<id> body=<text> — a durable message addressed to the agent ;
//!   2. the target agent reads its Unread(agent_id) on its poll loop, MarkReads,
//!      and Replies(id=<cid>, reply=...) ;
//!   3. this bin BLOCK-POLLS `state <cid>` until status == replied, then prints the
//!      reply on stdout. The reply is durable aggregate state ; the bin only gives
//!      it a synchronous face. The adapter CAN block — it runs out-of-process.
//!
//! Knows nothing about storehouse internals : it re-enters only the GENERIC door
//! (`storehouse <root> <FQN.Command> k=v`), with the bin + root handed in by env
//! (HECKS_STOREHOUSE_BIN / HECKS_ROOT) when the pump spawns it, or by args/defaults
//! when run standalone.
//!
//! Build : rustc -O adapters/agent/send-message.rs -o adapters/agent/send-message
//! Usage : send-message <agent_id> <text>   (root+bin via env, or --root <dir>)

use std::io::Read;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn debug(msg: &str) {
    if std::env::var("HECKS_DEBUG_MSG").is_ok() {
        eprintln!("[send-message] {}", msg);
    }
}

fn sh(bin: &str, args: &[&str]) -> (bool, String) {
    match Command::new(bin).args(args).output() {
        Ok(o) => (o.status.success(), String::from_utf8_lossy(&o.stdout).into_owned()),
        Err(e) => { debug(&format!("spawn {} failed: {}", bin, e)); (false, String::new()) }
    }
}

/// Minimal JSON string-field extractor (the state dispatch returns a flat
/// {"state":{"...":"..."}} object). UTF-8 safe.
fn field(src: &str, key: &str) -> Option<String> {
    let pat = format!("\"{}\"", key);
    let start = src.find(&pat)? + pat.len();
    let rest = &src[start..];
    let colon = rest.find(':')?;
    let after = &rest[colon + 1..];
    let q = after.find('"')?;
    let mut out = String::new();
    let mut chars = after[q + 1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(o) => out.push(o),
                None => break,
            },
            '"' => return Some(out),
            _ => out.push(c),
        }
    }
    None
}

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    // --root <dir> override (standalone) ; else HECKS_ROOT env (pump).
    let mut root = std::env::var("HECKS_ROOT").unwrap_or_default();
    let mut positional: Vec<String> = Vec::new();
    let mut i = 1;
    while i < argv.len() {
        if argv[i] == "--root" && i + 1 < argv.len() { root = argv[i + 1].clone(); i += 2; }
        else { positional.push(argv[i].clone()); i += 1; }
    }
    let bin = std::env::var("HECKS_STOREHOUSE_BIN").unwrap_or_else(|_| "storehouse".into());

    // agent_id + text : from args, else from a JSON payload on stdin (pump path).
    let (agent_id, text) = if positional.len() >= 2 {
        (positional[0].clone(), positional[1..].join(" "))
    } else {
        let mut raw = String::new();
        let _ = std::io::stdin().read_to_string(&mut raw);
        (field(&raw, "agent_id").unwrap_or_default(), field(&raw, "text").or_else(|| field(&raw, "body")).unwrap_or_default())
    };
    if agent_id.is_empty() || text.is_empty() {
        debug("missing agent_id or text");
        std::process::exit(2);
    }
    if root.is_empty() {
        debug("no root (set --root or HECKS_ROOT)");
        std::process::exit(2);
    }

    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let cid = format!("msg_{}_{}", std::process::id(), nanos);

    // 1. Send the message to the agent's inbox.
    let (ok, _) = sh(&bin, &[&root, "AgentInbox::AgentMessage.Send",
        &format!("id={}", cid), &format!("agent_id={}", agent_id),
        &format!("body={}", text), &format!("mid={}", cid)]);
    if !ok { debug("Send dispatch failed"); std::process::exit(1); }
    debug(&format!("sent {} -> agent {}", cid, agent_id));

    // 2. Block-poll state until the agent Replies (status == replied). ~5 min cap.
    for _ in 0..600 {
        let (_, out) = sh(&bin, &["state", &root, "AgentInbox::AgentMessage", &cid]);
        if field(&out, "status").as_deref() == Some("replied") {
            let reply = field(&out, "reply").unwrap_or_default();
            println!("{}", reply);
            return;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    debug("timed out waiting for reply");
    std::process::exit(1);
}
