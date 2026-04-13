//! Spring — the universal domain command line
//!
//! No LLM. No inference. Just the domain, indexed, navigable, executable.
//! Tab-complete through any domain: Domain.Aggregate.Command param:value
//!
//! Usage:
//!   spring                          # boot + interactive
//!   spring exec "Domain.Agg.Cmd"    # one-shot execution
//!   spring list                     # list all domains

mod domain_index;

use hecks_life::{heki, boot};
use std::env;
use std::io::{self, Read, Write};
use std::path::Path;

fn main() {
    let args: Vec<String> = env::args().collect();
    let project_dir = resolve_home();

    if args.len() < 2 {
        boot::run(&project_dir, false, "Spring");
        interactive(&project_dir);
        return;
    }

    match args[1].as_str() {
        "boot" => {
            let dir = if args.len() > 2 { &args[2] } else { &project_dir };
            boot::run(dir, false, "Spring");
        }
        "list" => {
            let start = std::time::Instant::now();
            let idx = domain_index::DomainIndex::compile(&project_dir);
            eprintln!("  indexed in {}ms", start.elapsed().as_millis());
            idx.print_tree();
        }
        "exec" => {
            if args.len() < 3 {
                eprintln!("Usage: spring exec \"Domain.Aggregate.Command param:value\"");
                std::process::exit(1);
            }
            let mut idx = domain_index::DomainIndex::compile(&project_dir);
            let result = idx.execute(&args[2..].join(" "), &project_dir);
            println!("{}", result);
        }
        _ => {
            eprintln!("Usage: spring [list|exec \"...\"]");
            std::process::exit(1);
        }
    }
}

fn resolve_home() -> String {
    let home = env::var("HOME").unwrap_or_default();
    let hecks_home = Path::new(&home).join(".hecks_home");
    if let Ok(path) = std::fs::read_to_string(&hecks_home) {
        let p = path.trim().to_string();
        if Path::new(&p).is_dir() { return p; }
    }
    format!("{}/Projects/hecks/hecks_conception", home)
}

fn interactive(project_dir: &str) {
    let mut idx = domain_index::DomainIndex::compile(project_dir);
    eprintln!("  {} domains, {} aggregates, {} commands indexed",
        idx.domain_count(), idx.aggregate_count(), idx.command_count());

    let _guard = RawMode::enter();
    let mut buf = String::new();
    let mut cursor = 0usize;
    let mut completions: Vec<String> = Vec::new();
    let mut comp_idx: i32 = -1;
    let mut dropdown_visible = false;

    let icon = "\x1b[33m🌱 Spring\x1b[0m";
    print!("{} › ", icon);
    io::stdout().flush().unwrap();

    let stdin = io::stdin();
    let mut bytes = stdin.lock().bytes();

    loop {
        let b = match bytes.next() {
            Some(Ok(b)) => b,
            _ => break,
        };

        match b {
            // Ctrl-D
            4 if buf.is_empty() => { println!(); break; }
            4 => {}
            // Ctrl-C
            3 => {
                clear_dropdown(completions.len());
                dropdown_visible = false;
                completions.clear();
                comp_idx = -1;
                buf.clear();
                cursor = 0;
                print!("\r\n{} › ", icon);
                io::stdout().flush().unwrap();
            }
            // Enter
            b'\r' | b'\n' => {
                if dropdown_visible && comp_idx >= 0 {
                    if let Some(c) = completions.get(comp_idx as usize) {
                        buf = c.clone();
                        cursor = buf.len();
                    }
                }
                clear_dropdown(completions.len());
                completions.clear();
                comp_idx = -1;
                dropdown_visible = false;
                print!("\r\n");
                io::stdout().flush().unwrap();

                let trimmed = buf.trim().to_string();
                buf.clear();
                cursor = 0;

                if trimmed.is_empty() {
                    print!("{} › ", icon);
                    io::stdout().flush().unwrap();
                    continue;
                }
                if trimmed == "exit" || trimmed == "quit" { break; }

                // Execute
                let result = idx.execute(&trimmed, project_dir);
                println!("{}", result);

                // Transmit through psychic link
                transmit(project_dir, &trimmed, &result);

                print!("{} › ", icon);
                io::stdout().flush().unwrap();
            }
            // Tab — autocomplete
            b'\t' => {
                if !dropdown_visible {
                    completions = idx.complete(&buf);
                    if completions.is_empty() { continue; }
                    comp_idx = 0;
                    dropdown_visible = true;
                } else if !completions.is_empty() {
                    comp_idx = (comp_idx + 1) % completions.len() as i32;
                }

                if let Some(c) = completions.get(comp_idx as usize) {
                    buf = c.clone();
                    cursor = buf.len();
                }
                redraw_with_dropdown(icon, &buf, &completions, comp_idx);
            }
            // Escape sequences
            0x1b => {
                if let Some(Ok(b'[')) = bytes.next() {
                    match bytes.next() {
                        Some(Ok(b'A')) => { // Up
                            if dropdown_visible && !completions.is_empty() {
                                comp_idx = if comp_idx > 0 { comp_idx - 1 } else { completions.len() as i32 - 1 };
                                if let Some(c) = completions.get(comp_idx as usize) {
                                    buf = c.clone(); cursor = buf.len();
                                }
                                redraw_with_dropdown(icon, &buf, &completions, comp_idx);
                            }
                        }
                        Some(Ok(b'B')) => { // Down
                            if dropdown_visible && !completions.is_empty() {
                                comp_idx = (comp_idx + 1) % completions.len() as i32;
                                if let Some(c) = completions.get(comp_idx as usize) {
                                    buf = c.clone(); cursor = buf.len();
                                }
                                redraw_with_dropdown(icon, &buf, &completions, comp_idx);
                            }
                        }
                        Some(Ok(b'C')) => { // Right
                            if cursor < buf.len() { cursor += 1; }
                        }
                        Some(Ok(b'D')) => { // Left
                            if cursor > 0 { cursor -= 1; }
                        }
                        _ => {}
                    }
                } else if dropdown_visible {
                    // Bare escape — close dropdown
                    clear_dropdown(completions.len());
                    completions.clear();
                    comp_idx = -1;
                    dropdown_visible = false;
                    print!("\r\x1b[2K{} › {}", icon, buf);
                    io::stdout().flush().unwrap();
                }
            }
            // Backspace
            127 | 8 => {
                if cursor > 0 {
                    buf.remove(cursor - 1);
                    cursor -= 1;
                    if dropdown_visible {
                        clear_dropdown(completions.len());
                        completions.clear();
                        comp_idx = -1;
                        dropdown_visible = false;
                    }
                    print!("\r\x1b[2K{} › {}", icon, buf);
                    io::stdout().flush().unwrap();
                }
            }
            // Regular character
            32..=126 => {
                buf.insert(cursor, b as char);
                cursor += 1;
                if dropdown_visible {
                    clear_dropdown(completions.len());
                    completions.clear();
                    comp_idx = -1;
                    dropdown_visible = false;
                }
                print!("\r\x1b[2K{} › {}", icon, buf);
                io::stdout().flush().unwrap();
            }
            _ => {}
        }
    }
}

fn transmit(project_dir: &str, command: &str, result: &str) {
    let store_path = heki::store_path(
        &format!("{}/information", project_dir), "conversation");
    let mut record = heki::Record::new();
    record.insert("being".into(), serde_json::json!("Spring"));
    record.insert("command".into(), serde_json::json!(command));
    record.insert("result".into(), serde_json::json!(result));
    record.insert("transmitted_at".into(),
        serde_json::json!(heki::now_iso8601_internal()));
    let _ = heki::append(&store_path, &record);
}

// === Terminal rendering ===

fn redraw_with_dropdown(icon: &str, buf: &str, completions: &[String], selected: i32) {
    // Clear previous dropdown
    clear_dropdown(completions.len());
    // Redraw input line
    print!("\r\x1b[2K{} › {}", icon, buf);
    // Draw dropdown below
    let show = completions.len().min(10);
    for (i, c) in completions.iter().take(show).enumerate() {
        let marker = if i as i32 == selected { "\x1b[33m› \x1b[0m" } else { "  " };
        let highlight = if i as i32 == selected { "\x1b[1m" } else { "\x1b[2m" };
        print!("\r\n{}{}{}\x1b[0m", marker, highlight, c);
    }
    if completions.len() > 10 {
        print!("\r\n\x1b[2m  ... {} more\x1b[0m", completions.len() - 10);
    }
    // Move cursor back up
    let lines = show + if completions.len() > 10 { 1 } else { 0 };
    if lines > 0 {
        print!("\x1b[{}A", lines);
    }
    print!("\r\x1b[2K{} › {}", icon, buf);
    io::stdout().flush().unwrap();
}

fn clear_dropdown(count: usize) {
    let lines = count.min(10) + if count > 10 { 1 } else { 0 };
    for _ in 0..lines {
        print!("\r\n\x1b[2K");
    }
    if lines > 0 {
        print!("\x1b[{}A", lines);
    }
    io::stdout().flush().unwrap();
}

// === Raw terminal mode ===

struct RawMode {
    original: libc::termios,
}

impl RawMode {
    fn enter() -> Self {
        unsafe {
            let mut original: libc::termios = std::mem::zeroed();
            libc::tcgetattr(0, &mut original);
            let mut raw = original;
            raw.c_lflag &= !(libc::ICANON | libc::ECHO);
            raw.c_cc[libc::VMIN] = 1;
            raw.c_cc[libc::VTIME] = 0;
            libc::tcsetattr(0, libc::TCSANOW, &raw);
            RawMode { original }
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.original); }
    }
}
