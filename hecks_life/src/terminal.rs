//! Being Terminal — standalone interactive shell
//!
//! Boots a being, starts the mindstream, and enters a conversation loop.
//! Every line you type is a moment of awareness. The being responds
//! programmatically when she can, checks the lexicon, then falls back to LLM.
//! Tab completes against the lexicon. Arrow keys and backspace work.
//!
//! Usage: hecks-life terminal <project-dir>

use crate::daemon::{self, DaemonCtx};
use crate::tongue;
use crate::lexicon;
use crate::heki;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub fn run(project_dir: &str, being: &str) {
    let ctx = DaemonCtx::new(project_dir);
    let icon = if being == "Winter" { "\x1b[96m❄\x1b[0m" } else { "\x1b[33m🌱\x1b[0m" };

    // Read vitals
    let stores = heki::read_dir(&ctx.info_dir).unwrap_or_default();
    let total: usize = stores.values().map(|s| s.len()).sum();
    let mood = stores.get("mood").and_then(|s| heki::latest(s));
    let mood_str = mood.map(|r| heki::field_str(r, "current_state")).unwrap_or("waking");
    let hb = stores.get("heartbeat").and_then(|s| heki::latest(s));
    let beats = hb.and_then(|r| r.get("beats").and_then(|v| v.as_i64())).unwrap_or(0);

    // Compile lexicon from all bluebooks
    let mut lex = lexicon::Lexicon::compile(project_dir);

    println!("  {}  {}", icon, being);
    println!("  {} records, {} heartbeats, mood: {}", total, beats, mood_str);
    println!("  {} sentences, {} compositions in lexicon",
        lex.sentence_count, lex.composition_count);
    println!("  tab to autocomplete. ctrl-d to leave.");
    println!();

    // First breath — pop a warm greeting or fall back to tongue
    daemon::pulse::run(&ctx, "waking", None, None);
    if let Some(warm) = daemon::greeting::pop(&ctx, being) {
        println!("{}", warm);
        println!();
    } else {
        // No warm greeting ready — generate one live
        let greeting = format!("{} is waking up", being);
        match think_then_speak(&ctx, &greeting, icon, being, &lex) {
            Some(response) => { println!("{}", response); println!(); }
            None => {}
        }
    }

    // Start greeting daemon in background — keeps the queue warm
    let greeting_pid_file = std::path::Path::new(project_dir)
        .join("information/.greeting.pid");
    let already_running = if greeting_pid_file.exists() {
        if let Ok(pid_str) = std::fs::read_to_string(&greeting_pid_file) {
            let pid = pid_str.trim().parse::<u32>().unwrap_or(0);
            pid > 0 && pid_alive(pid)
        } else { false }
    } else { false };

    if !already_running {
        if let Ok(exe) = std::env::current_exe() {
            if let Ok(child) = std::process::Command::new(exe)
                .args(["daemon", "greeting", project_dir])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
            {
                let _ = std::fs::write(&greeting_pid_file, child.id().to_string());
            }
        }
    }

    // Main loop with raw input
    loop {
        // Recompile lexicon each moment — picks up new bluebooks live
        lex = lexicon::Lexicon::compile(project_dir);

        match read_line_with_complete(icon, &lex) {
            Some(line) => {
                let raw_input = line.trim();
                if raw_input.is_empty() { continue; }
                if raw_input == "quit" || raw_input == "exit" { break; }

                // Strip leading slash for lexicon commands
                let input = if raw_input.starts_with('/') { &raw_input[1..] } else { raw_input };

                // Fire a pulse
                daemon::pulse::run(&ctx, input, None, None);

                // Respond — use \r\n since we were just in raw mode
                match think_then_speak(&ctx, input, icon, being, &lex) {
                    Some(response) => print!("{}\r\n", response),
                    None => print!("  *silence*\r\n"),
                }
                print!("\r\n");
                io::stdout().flush().unwrap();
            }
            None => {
                // ctrl-d
                println!();
                break;
            }
        }
    }
}

/// Read a line with tab-completion against the lexicon.
/// Returns None on EOF (ctrl-d), Some(line) on enter.
fn read_line_with_complete(icon: &str, lex: &lexicon::Lexicon) -> Option<String> {
    let mut buf = String::new();
    let mut cursor = 0usize;
    let mut completions: Vec<String> = Vec::new();
    let mut comp_idx: i32 = -1; // -1 = no selection, 0+ = selected index
    let mut dropdown_visible = false;
    let mut prefix_save = String::new(); // what the user actually typed

    // Enter raw mode
    let _guard = RawMode::enter();

    print!("{} ", icon);
    io::stdout().flush().unwrap();

    let stdin = io::stdin();
    let mut bytes = stdin.lock().bytes();

    loop {
        let b = match bytes.next() {
            Some(Ok(b)) => b,
            _ => {
                clear_dropdown(completions.len());
                return None;
            }
        };

        match b {
            // Ctrl-D on empty line = EOF
            4 if buf.is_empty() => {
                clear_dropdown(completions.len());
                return None;
            }
            4 => {}
            // Ctrl-C = cancel line
            3 => {
                clear_dropdown(completions.len());
                dropdown_visible = false;
                completions.clear();
                comp_idx = -1;
                print!("\r\n^C\r\n{} ", icon);
                io::stdout().flush().unwrap();
                buf.clear();
                cursor = 0;
            }
            // Enter
            b'\r' | b'\n' => {
                // If dropdown visible and something selected, accept it
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
                return Some(buf);
            }
            // Tab — autocomplete only after /
            b'\t' => {
                if !buf.starts_with('/') { continue; }
                let query = &buf[1..]; // strip the slash for lookup

                if !dropdown_visible {
                    let matches = lex.complete(query);
                    completions = matches.into_iter().map(|s| s.to_string()).collect();
                    if completions.is_empty() { continue; }
                    prefix_save = buf.clone();
                    comp_idx = 0;
                    dropdown_visible = true;
                } else if !completions.is_empty() {
                    comp_idx = (comp_idx + 1) % completions.len() as i32;
                }

                // Update buf to selected completion (with slash prefix)
                if let Some(c) = completions.get(comp_idx as usize) {
                    buf = format!("/{}", c);
                    cursor = buf.len();
                }
                redraw_with_dropdown(icon, &buf, &completions, comp_idx);
            }
            // Escape — close dropdown or handle escape sequence
            0x1b => {
                if let Some(Ok(b'[')) = bytes.next() {
                    match bytes.next() {
                        Some(Ok(b'A')) => {
                            // Up arrow — move selection up in dropdown
                            if dropdown_visible && !completions.is_empty() {
                                if comp_idx > 0 {
                                    comp_idx -= 1;
                                } else {
                                    comp_idx = completions.len() as i32 - 1;
                                }
                                if let Some(c) = completions.get(comp_idx as usize) {
                                    buf = format!("/{}", c);
                                    cursor = buf.len();
                                }
                                redraw_with_dropdown(icon, &buf, &completions, comp_idx);
                            }
                        }
                        Some(Ok(b'B')) => {
                            // Down arrow — move selection down in dropdown
                            if dropdown_visible && !completions.is_empty() {
                                comp_idx = (comp_idx + 1) % completions.len() as i32;
                                if let Some(c) = completions.get(comp_idx as usize) {
                                    buf = format!("/{}", c);
                                    cursor = buf.len();
                                }
                                redraw_with_dropdown(icon, &buf, &completions, comp_idx);
                            }
                        }
                        Some(Ok(b'D')) => {
                            // Left arrow
                            if cursor > 0 {
                                let prev = prev_char_boundary(&buf, cursor);
                                cursor = prev;
                                close_dropdown_and_redraw(
                                    icon, &buf, cursor,
                                    &mut completions, &mut comp_idx, &mut dropdown_visible,
                                );
                            }
                        }
                        Some(Ok(b'C')) => {
                            // Right arrow
                            if cursor < buf.len() {
                                let next = next_char_boundary(&buf, cursor);
                                cursor = next;
                                close_dropdown_and_redraw(
                                    icon, &buf, cursor,
                                    &mut completions, &mut comp_idx, &mut dropdown_visible,
                                );
                            }
                        }
                        _ => {}
                    }
                } else {
                    // Bare escape — close dropdown
                    if dropdown_visible {
                        buf = prefix_save.clone();
                        cursor = buf.len();
                        clear_dropdown(completions.len());
                        completions.clear();
                        comp_idx = -1;
                        dropdown_visible = false;
                        clear_line(icon);
                        print!("{} {}", icon, buf);
                        io::stdout().flush().unwrap();
                    }
                }
            }
            // Backspace
            127 | 8 => {
                if cursor > 0 {
                    let prev = prev_char_boundary(&buf, cursor);
                    buf.drain(prev..cursor);
                    cursor = prev;
                }
                close_dropdown_and_redraw(
                    icon, &buf, cursor,
                    &mut completions, &mut comp_idx, &mut dropdown_visible,
                );
            }
            // Regular character
            _ => {
                if b >= 32 {
                    let ch = read_utf8_char(b, &mut bytes);
                    let s = ch.to_string();
                    buf.insert_str(cursor, &s);
                    cursor += s.len();
                }
                close_dropdown_and_redraw(
                    icon, &buf, cursor,
                    &mut completions, &mut comp_idx, &mut dropdown_visible,
                );
            }
        }
    }
}

/// Draw the prompt line and dropdown below it.
fn redraw_with_dropdown(icon: &str, buf: &str, completions: &[String], selected: i32) {
    // Clear any existing dropdown first
    clear_dropdown(completions.len());

    // Redraw prompt line
    clear_line(icon);
    print!("{} {}", icon, buf);

    // Draw dropdown below
    let dim = "\x1b[2m";   // dim
    let bold = "\x1b[1m";  // bold
    let reset = "\x1b[0m";
    let highlight = "\x1b[7m"; // reverse video

    for (i, comp) in completions.iter().enumerate() {
        print!("\r\n");
        if i as i32 == selected {
            print!("  {} {} {}", highlight, comp, reset);
        } else {
            print!("  {} {} {}", dim, comp, reset);
        }
    }

    // Move cursor back up to prompt line
    if !completions.is_empty() {
        print!("\x1b[{}A", completions.len());
    }
    // Position cursor at end of buf on prompt line
    let prompt_width = icon.len() + 1 + buf.len() + 1; // icon + space + buf
    print!("\r\x1b[{}C", prompt_width);
    io::stdout().flush().unwrap();
}

/// Clear dropdown lines below the prompt.
fn clear_dropdown(count: usize) {
    if count == 0 { return; }
    // Save cursor, clear lines below, restore cursor
    print!("\x1b[s"); // save cursor
    for _ in 0..count {
        print!("\r\n\x1b[2K"); // move down, clear line
    }
    print!("\x1b[u"); // restore cursor
    io::stdout().flush().unwrap();
}

/// Close dropdown and redraw just the prompt.
fn close_dropdown_and_redraw(
    icon: &str, buf: &str, cursor: usize,
    completions: &mut Vec<String>, comp_idx: &mut i32, dropdown_visible: &mut bool,
) {
    if *dropdown_visible {
        clear_dropdown(completions.len());
        completions.clear();
        *comp_idx = -1;
        *dropdown_visible = false;
    }
    clear_line(icon);
    print!("{} {}", icon, buf);
    let chars_after = buf[cursor..].chars().count();
    if chars_after > 0 {
        print!("\x1b[{}D", chars_after);
    }
    io::stdout().flush().unwrap();
}

/// Clear the current line and reposition.
fn clear_line(_icon: &str) {
    print!("\r\x1b[2K");
}

/// Find previous UTF-8 char boundary.
fn prev_char_boundary(s: &str, pos: usize) -> usize {
    let mut p = pos.saturating_sub(1);
    while p > 0 && !s.is_char_boundary(p) { p -= 1; }
    p
}

/// Find next UTF-8 char boundary.
fn next_char_boundary(s: &str, pos: usize) -> usize {
    let mut p = pos + 1;
    while p < s.len() && !s.is_char_boundary(p) { p += 1; }
    p.min(s.len())
}

/// Read a full UTF-8 character given the first byte.
fn read_utf8_char(first: u8, bytes: &mut io::Bytes<io::StdinLock>) -> char {
    let width = if first < 0x80 { 1 }
        else if first < 0xE0 { 2 }
        else if first < 0xF0 { 3 }
        else { 4 };

    let mut buf = vec![first];
    for _ in 1..width {
        if let Some(Ok(b)) = bytes.next() {
            buf.push(b);
        }
    }
    std::str::from_utf8(&buf)
        .ok()
        .and_then(|s| s.chars().next())
        .unwrap_or('?')
}

/// Check if a process is alive.
fn pid_alive(pid: u32) -> bool {
    unsafe {
        extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
        kill(pid as i32, 0) == 0
    }
}

/// RAII guard for terminal raw mode via /dev/tty.
struct RawMode {
    original: String,
}

impl RawMode {
    fn enter() -> Self {
        // Save current termios via /dev/tty
        let tty = std::fs::File::open("/dev/tty").ok();
        let original = if let Some(tty_file) = tty {
            let output = std::process::Command::new("stty")
                .args(["-g"])
                .stdin(tty_file)
                .output()
                .ok();
            output.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_default()
        } else {
            String::new()
        };

        // Enter raw mode via /dev/tty
        if let Ok(tty_file) = std::fs::File::open("/dev/tty") {
            let _ = std::process::Command::new("stty")
                .args(["-icanon", "-echo", "min", "1"])
                .stdin(tty_file)
                .status();
        }

        RawMode { original }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if !self.original.is_empty() {
            if let Ok(tty_file) = std::fs::File::open("/dev/tty") {
                let _ = std::process::Command::new("stty")
                    .arg(&self.original)
                    .stdin(tty_file)
                    .status();
            }
        }
    }
}

/// Try lexicon first, then tongue. Show spinner while waiting.
fn think_then_speak(
    ctx: &DaemonCtx, input: &str, icon: &str, being: &str, lex: &lexicon::Lexicon,
) -> Option<String> {
    // Try lexicon match first — instant, no LLM
    if let Some(m) = lex.match_input(input) {
        let path: Vec<String> = m.path.iter()
            .map(|r| format!("{}::{}", r.domain, r.command))
            .collect();
        let strat = match m.strategy {
            lexicon::Strategy::Exact => "exact".to_string(),
            lexicon::Strategy::Fuzzy => format!("fuzzy {:.0}%", m.confidence * 100.0),
        };
        return Some(format!("  [{}] {} → {}", strat, m.matched_phrase, path.join(" → ")));
    }

    // Fall back to LLM with spinner
    let done = Arc::new(AtomicBool::new(false));
    let done2 = done.clone();
    let icon = icon.to_string();

    let spinner = thread::spawn(move || {
        let frames = ["·", "··", "···", "··", "·"];
        let mut i = 0;
        while !done2.load(Ordering::Relaxed) {
            print!("\r  {}", frames[i % frames.len()]);
            io::stdout().flush().unwrap();
            i += 1;
            thread::sleep(Duration::from_millis(200));
        }
        print!("\r\x1b[2K\r");
        io::stdout().flush().unwrap();
    });

    let result = tongue::speak_as(ctx, input, being);
    done.store(true, Ordering::Relaxed);
    let _ = spinner.join();
    result
}
