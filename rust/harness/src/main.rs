//! The `hecks-harness` binary.
//!
//! - `hecks-harness serve [--record DIR] [--tick-ms MS]`: the supervisor, ops on stdin and tells
//!   on stdout, with a `tick` tell every `MS` milliseconds (a minute unless given).
//! - `hecks-harness replay TAPE`: a Claude Code child played from a tape.
//! - `hecks-harness measure TELLS`: the mail measured against the baseline, as JSON; exits 1 when
//!   it is not within the baseline.
//! - `hecks-harness tape RECORDING`: a recording `serve --record` wrote, turned into a tape.
//! - `hecks-harness brief ROLE_FILE`: the brief a session opened for that role is given.

use std::fs;
use std::io::{self, BufReader};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use hecks_harness::{brief, measure, replay, supervisor};

const USAGE: &str =
    "usage: hecks-harness serve [--record DIR] [--tick-ms MS] | replay TAPE | measure TELLS | tape RECORDING | brief ROLE_FILE";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let outcome = match words.as_slice() {
        ["serve", flags @ ..] => served(flags).and_then(|(record, tick)| serve(record, tick)),
        ["replay", tape] => play(tape),
        ["measure", tells] => return measured(tells),
        ["tape", recording] => read(recording)
            .and_then(|text| replay::tape_from_recording(&text))
            .map(|tape| print!("{tape}")),
        ["brief", role_file] => read(role_file).map(|text| print!("{}", brief::of_role(&text))),
        _ => Err(USAGE.to_string()),
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("hecks-harness: {error}");
            ExitCode::from(2)
        }
    }
}

/// The recording directory and the tick `serve`'s flags name, each at most once, in any order.
fn served(flags: &[&str]) -> Result<(Option<PathBuf>, Duration), String> {
    let mut record = None;
    let mut tick = None;
    for pair in flags.chunks(2) {
        match pair {
            ["--record", dir] if record.is_none() => record = Some(PathBuf::from(dir)),
            ["--tick-ms", ms] if tick.is_none() => {
                let ms: u64 = ms.parse().ok().filter(|ms| *ms > 0).ok_or_else(|| {
                    format!("--tick-ms takes a whole number of milliseconds above 0, not {ms:?}")
                })?;
                tick = Some(Duration::from_millis(ms));
            }
            _ => return Err(USAGE.to_string()),
        }
    }
    Ok((record, tick.unwrap_or(supervisor::TICK)))
}

fn serve(record: Option<PathBuf>, tick: Duration) -> Result<(), String> {
    supervisor::serve(
        BufReader::new(io::stdin()),
        io::stdout().lock(),
        record,
        tick,
    )
}

fn play(tape: &str) -> Result<(), String> {
    let steps = replay::steps(&read(tape)?)?;
    replay::play(
        &steps,
        BufReader::new(io::stdin()),
        &mut io::stdout().lock(),
    )
}

fn measured(tells: &str) -> ExitCode {
    match read(tells) {
        Ok(text) => {
            let measured = measure::measure(&text);
            println!("{}", measured.to_value().to_json());
            if measured.within_baseline() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Err(error) => {
            eprintln!("hecks-harness: {error}");
            ExitCode::from(2)
        }
    }
}

fn read(path: &str) -> Result<String, String> {
    fs::read_to_string(path).map_err(|error| format!("cannot read {path}: {error}"))
}
