//! CLI entrypoint: reads a `{"steps": [...]}` script from stdin, prints
//! `{"instances", "events", "refusals"}`. Domain-agnostic; also built for wasm32-wasip1.
use std::io::Read;

fn main() {
    // `--serve`: one step per line in, one answer per line out, store kept alive.
    if std::env::args().any(|a| a == "--serve") {
        let stdin = std::io::stdin();
        let stdout = std::io::stdout();
        rust::kernel::cli::serve(stdin.lock(), stdout.lock());
        return;
    }
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("failed to read stdin");
    println!("{}", rust::kernel::cli::run(&input));
}
