//! `storehouse follow [stream] [--json] [--exclude D1,D2,...]` — tail the
//! storehouse bus log. [antibody-exempt: rust/src/run_follow/mod.rs —
//! kernel-surface CLI primitive paired with runtime/storehouse_log.rs +
//! runtime/dispatch_detail.rs ; owns the file-watch + block-assembly +
//! render loop. Retires with storehouse_log's exemption.]
//!
//! Block-driven : assemble each blank-line-separated paragraph ; if it
//! parses as a rich dispatch block render one terse line (default) or the
//! full re-colourised block (--json). Stray terse one-liners suppressed.
//!   storehouse follow                 # terse, one line per dispatch
//!   storehouse follow --json          # full colourised JSON block
//!   storehouse follow --exclude Heart,SpeechStream
//!   storehouse follow ShellTool       # substring filter on command FQN

use crate::runtime::storehouse_log;
mod block;
use block::Block;
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Clone)]
pub enum Filter { All, Surface(&'static str), Substring(String) }

impl Filter {
    pub fn from_arg(arg: Option<&str>) -> Filter {
        match arg {
            None | Some("") | Some("all") => Filter::All,
            Some("dispatch") => Filter::Surface("dispatch"),
            Some("event") => Filter::Surface("event"),
            Some("cascade") => Filter::Surface("cascade"),
            Some("policy") => Filter::Surface("policy"),
            Some(s) => Filter::Substring(s.to_string()),
        }
    }
    pub fn accepts_block(&self, b: &Block) -> bool {
        match self {
            Filter::All => true,
            Filter::Surface("dispatch") => true,
            Filter::Surface(w) => b.command.contains(*w),
            Filter::Substring(needle) => b.command.contains(needle.as_str()),
        }
    }
}

struct Opts { filter: Filter, json: bool, exclude: Vec<String> }

fn parse_opts(args: &[String]) -> Opts {
    let mut json = false;
    let mut exclude: Vec<String> = Vec::new();
    let mut stream: Option<String> = None;
    let mut i = 2;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--json" { json = true; }
        else if a == "--exclude" { if let Some(v) = args.get(i + 1) { exclude = split_csv(v); i += 1; } }
        else if let Some(v) = a.strip_prefix("--exclude=") { exclude = split_csv(v); }
        else if !a.starts_with('-') && stream.is_none() { stream = Some(a.to_string()); }
        i += 1;
    }
    Opts { filter: Filter::from_arg(stream.as_deref()), json, exclude }
}

fn split_csv(v: &str) -> Vec<String> {
    v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

fn excluded(b: &Block, exclude: &[String]) -> bool {
    exclude.iter().any(|x| x == b.domain() || x == b.aggregate() || b.command.contains(x.as_str()))
}

pub fn print_help() {
    let path = storehouse_log::log_file_path();
    println!("storehouse follow [stream] [--json] [--exclude D1,D2,...]");
    println!();
    println!("  storehouse follow                  # terse, one line per dispatch");
    println!("  storehouse follow --json           # full colourised JSON block");
    println!("  storehouse follow --exclude Heart,SpeechStream");
    println!("  storehouse follow ShellTool        # command FQN substring filter");
    println!();
    println!("Log: $STOREHOUSE_LOG_FILE (default {}).", path.display());
}

pub fn run(args: &[String]) -> i32 {
    let first = args.get(2).map(|s| s.as_str());
    if matches!(first, Some("--help") | Some("-h") | Some("help")) { print_help(); return 0; }
    let opts = parse_opts(args);
    let path = storehouse_log::log_file_path();
    tail_blocks(&path, &opts);
    0
}

fn tail_blocks(path: &Path, opts: &Opts) {
    let poll = Duration::from_millis(100);
    let mut file = loop { match File::open(path) { Ok(f) => break f, Err(_) => std::thread::sleep(poll) } };
    let _ = file.seek(SeekFrom::End(0));
    let mut reader = BufReader::new(file);
    let mut buf = String::new();
    let mut para = String::new();
    loop {
        buf.clear();
        match reader.read_line(&mut buf) {
            Ok(0) => {
                std::thread::sleep(poll);
                if !path.exists() {
                    let nf = loop { match File::open(path) { Ok(f) => break f, Err(_) => std::thread::sleep(poll) } };
                    reader = BufReader::new(nf);
                }
            }
            Ok(_) => {
                let line = buf.trim_end_matches('\n').trim_end_matches('\r');
                if line.is_empty() { flush_para(&para, opts); para.clear(); }
                else { if !para.is_empty() { para.push('\n'); } para.push_str(line); }
            }
            Err(_) => std::thread::sleep(poll),
        }
    }
}

fn flush_para(para: &str, opts: &Opts) {
    let para = para.trim();
    if para.is_empty() { return; }
    let Some(b) = Block::parse(para) else { return };
    if !opts.filter.accepts_block(&b) || excluded(&b, &opts.exclude) { return; }
    let rendered = if opts.json { format!("{}\n", block::colourise_json(para)) } else { b.terse() };
    println!("{}", rendered);
    use std::io::Write as _;
    let _ = std::io::stdout().flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse_opts_json_and_exclude() {
        let args = vec!["s".into(), "follow".into(), "all".into(), "--json".into(), "--exclude".into(), "Heart,SpeechStream".into()];
        let o = parse_opts(&args);
        assert!(o.json);
        assert_eq!(o.exclude, vec!["Heart", "SpeechStream"]);
        assert!(matches!(o.filter, Filter::All));
    }
    #[test]
    fn excluded_matches_domain_or_aggregate() {
        let b = Block { command: "Heart::Heart.Beat".into(), outcome: "ok".into(), elapsed_ms: 3, event_count: 1, source_tag: "x".into() };
        assert!(excluded(&b, &["Heart".to_string()]));
        assert!(!excluded(&b, &["Voice".to_string()]));
    }
    #[test]
    fn accepts_block_substring() {
        let b = Block { command: "Tools::ShellTool.Bash".into(), outcome: "ok".into(), elapsed_ms: 0, event_count: 0, source_tag: "x".into() };
        assert!(Filter::from_arg(Some("ShellTool")).accepts_block(&b));
        assert!(!Filter::from_arg(Some("FileTool")).accepts_block(&b));
    }
}
