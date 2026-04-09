//! Hecks Life — the Bluebook compiler
//!
//! Reads .bluebook files and projects them into target languages.
//! The Bluebook is DNA. This is the ribosome.
//!
//! Usage:
//!   hecks-life examples/pizzas/hecks/pizzas.bluebook

mod parser;
mod ir;

use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: hecks-life <bluebook-file>");
        std::process::exit(1);
    }

    let path = &args[1];
    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e);
        std::process::exit(1);
    });

    let domain = parser::parse(&source);
    println!("{}", domain);
}
