//! Holds the hecksagon boundary inside `rust/host`: the modules that run a domain (dispatch, the
//! journal, the sandbox, minting, the IR and the expression and presentation code) know nothing
//! of transport. HTTP, cookies, the process environment and the AWS SDK are adapters, and they
//! live outside these files: in `web`, `api`, `server`, `auth`, the payment modules, the AWS
//! adapters and `boot`, which reads the environment and hands each runtime module what it needs.
//!
//! The scan reads each runtime module's own source, skipping comment lines and its
//! `#[cfg(test)]` modules, which are test scaffolding rather than runtime code.

/// The modules that run a domain, with their source.
const RUNTIME_MODULES: &[(&str, &str)] = &[
    ("dispatch.rs", include_str!("../core/src/dispatch.rs")),
    ("journal.rs", include_str!("../core/src/journal.rs")),
    ("wasm_runner.rs", include_str!("../core/src/wasm_runner.rs")),
    ("needs.rs", include_str!("../core/src/needs.rs")),
    ("query_step.rs", include_str!("../core/src/query_step.rs")),
    (
        "presentation.rs",
        include_str!("../core/src/presentation.rs"),
    ),
    (
        "presentation_write.rs",
        include_str!("../core/src/presentation_write.rs"),
    ),
    ("ir.rs", include_str!("../core/src/ir.rs")),
    ("expr_json.rs", include_str!("../core/src/expr_json.rs")),
    (
        "lambda_client.rs",
        include_str!("../core/src/lambda_client.rs"),
    ),
    ("clock.rs", include_str!("../core/src/clock.rs")),
    (
        "storage_shape.rs",
        include_str!("../core/src/storage_shape.rs"),
    ),
    (
        "reference_transform.rs",
        include_str!("../core/src/reference_transform.rs"),
    ),
    (
        "reference_validate.rs",
        include_str!("../core/src/reference_validate.rs"),
    ),
];

/// Transport crates and types, the process environment, and the host's adapter modules.
const FORBIDDEN: &[&str] = &[
    "axum",
    "reqwest",
    "hyper",
    "http::",
    "HeaderMap",
    "StatusCode",
    "std::env",
    "aws_sdk",
    "lambda_runtime",
    "tokio_postgres",
    "crate::auth",
    "crate::web",
    "crate::server",
    "crate::api",
    "crate::rate_limit",
    "crate::platform_signin",
    "crate::payments",
    "crate::checkout",
    "crate::resend",
    "crate::secrets",
];

/// The `(line number, line)` pairs of `source` that are runtime code: comment lines and
/// `#[cfg(test)]` modules are left out.
fn runtime_lines(source: &str) -> Vec<(usize, &str)> {
    let mut kept = Vec::new();
    let mut lines = source.lines().enumerate().peekable();
    while let Some((index, line)) = lines.next() {
        if line == "#[cfg(test)]" || line == "#[cfg(any(test, feature = \"test-support\"))]" {
            skip_test_item(&mut lines);
            continue;
        }
        if !line.trim_start().starts_with("//") {
            kept.push((index + 1, line));
        }
    }
    kept
}

/// Skips the item after a top-level `#[cfg(test)]` when it is a module: an inline one through
/// its closing `}` at column 0, a `#[path]` one through its `;`.
fn skip_test_item<'a>(lines: &mut std::iter::Peekable<impl Iterator<Item = (usize, &'a str)>>) {
    while lines
        .peek()
        .is_some_and(|(_, line)| line.trim_start().starts_with("#["))
    {
        lines.next();
    }
    let Some((_, item)) = lines.peek() else {
        return;
    };
    let declaration = item.trim_start();
    let is_module = ["mod ", "pub mod ", "pub(crate) mod "]
        .iter()
        .any(|prefix| declaration.starts_with(prefix));
    if !is_module {
        return;
    }
    if declaration.trim_end().ends_with(';') {
        lines.next();
        return;
    }
    for (_, line) in lines.by_ref() {
        if line == "}" {
            return;
        }
    }
}

#[test]
fn runtime_modules_know_nothing_of_transport_or_the_environment() {
    let leaks: Vec<String> = RUNTIME_MODULES
        .iter()
        .flat_map(|(file, source)| {
            runtime_lines(source)
                .into_iter()
                .flat_map(move |(number, line)| {
                    FORBIDDEN
                        .iter()
                        .filter(move |token| line.contains(*token))
                        .map(move |token| {
                            format!("rust/host/core/src/{file}:{number}: `{token}` in {line:?}")
                        })
                })
        })
        .collect();
    assert!(
        leaks.is_empty(),
        "runtime modules reach across the hecksagon boundary; transport, the environment and \
         the AWS SDK are adapters and belong outside the runtime (in web, api, server, auth, the \
         AWS adapters or boot, which passes the runtime what it needs):\n{}",
        leaks.join("\n")
    );
}

#[test]
fn the_scan_skips_comments_and_test_modules_but_sees_runtime_code() {
    let source = "// std::env in a comment\nfn a() {}\n#[cfg(test)]\nmod tests {\n    \
                  use std::env;\n}\nfn b() { std::env::var(\"X\"); }\n";
    let lines: Vec<usize> = runtime_lines(source).iter().map(|(n, _)| *n).collect();
    assert_eq!(lines, vec![2, 7]);
}
