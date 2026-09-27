// **The sandbox boundary** — runs the compiled `.wasm` artifact (built by
// bin/project_wasm, the exact same wasm32-wasip1 module
// bin/rust_conformance's own WASM mode already verifies byte-for-byte
// against native) through an embedded wasmtime instance. This is the
// only place in rust/host that touches wasmtime; everything else (the
// Postgres journal, the Lambda handler) only ever sees plain JSON
// strings in and out — the module itself never gets a socket, a file,
// or any ambient capability beyond the stdin bytes it's handed here.
//
// WASIp1 (`wasm32-wasip1`, what bin/project_wasm builds) speaks
// stdin/stdout the same way a native process does
// (docs/implemented/decisions/0012-wasm-via-wasi-stdio.md) — `MemoryInputPipe`/
// `MemoryOutputPipe` (wasmtime_wasi::p2::pipe) are the in-process
// equivalent of piping a string to/from a subprocess, without actually
// spawning one. Neither implements `StdinStream`/`StdoutStream`
// directly in this wasmtime-wasi version, so the two thin wrappers
// below just forward to them — no behavior of their own.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::io::{AsyncRead, AsyncWrite};
use wasmtime::{Engine, Linker, Module, Store};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::p2::pipe::{MemoryInputPipe, MemoryOutputPipe};
use wasmtime_wasi::WasiCtxBuilder;

#[derive(Clone)]
struct StepsIn(MemoryInputPipe);

impl IsTerminal for StepsIn {
    fn is_terminal(&self) -> bool {
        false
    }
}

impl StdinStream for StepsIn {
    fn async_stream(&self) -> Box<dyn AsyncRead + Send + Sync> {
        Box::new(self.0.clone())
    }
}

#[derive(Clone)]
struct StepsOut(MemoryOutputPipe);

impl IsTerminal for StepsOut {
    fn is_terminal(&self) -> bool {
        false
    }
}

impl StdoutStream for StepsOut {
    fn async_stream(&self) -> Box<dyn AsyncWrite + Send + Sync> {
        Box::new(self.0.clone())
    }
}

// Compiled once per (warm) lambda execution environment, not once per
// call — `Engine`/`Module` hold only the compiled artifact, no
// per-invocation state at all (that lives entirely in `Store`, still
// created fresh below, every call), so caching them leaks nothing
// between invocations. Without this caching, every command dispatch
// (`dispatch::handle`) would pay a real, live cost: it runs through
// here, and `Module::from_file` is wasmtime doing real JIT compilation
// from raw bytes — a genuine multi-second cost on Lambda's own CPU
// allocation, paid again on every single warm call, not just a true
// cold start. `dispatch::read`'s own fast path (a snapshot with nothing
// to replay) never reaches this function at all, which is why reads
// stay fast while every command would otherwise cost far more than the
// actual rehydrate-replay work here ever needs to.
//
// Keyed by `wasm_path`, not a bare single slot — a deployed Lambda's own
// `HECKS_WASM_PATH` never changes across its whole warm lifetime, which
// is exactly why the original single-slot `OnceLock<(Engine, Module)>`
// stayed invisible in production: every call in that process really was
// the same path, forever. Found live, in this crate's own `cargo test`:
// one test binary genuinely dispatches against two different domains'
// `.wasm` files in the same process (dispatch.rs's own banking.wasm
// fixtures alongside web.rs's own site wasm ones, run concurrently
// by cargo test's own thread pool) — whichever path happened to compile
// first silently won for every subsequent call regardless of its own
// `wasm_path` argument, so a banking dispatch got a client site's compiled
// module back and refused every real Banking verb as "unknown command."
// `Engine`/`Module` are both cheap-`Clone` (wasmtime's own docs: each
// wraps an `Arc` internally), so caching owned clones per path costs
// nothing beyond the HashMap entry itself.
static ENGINE_AND_MODULE: OnceLock<Mutex<HashMap<PathBuf, Arc<Compiled>>>> = OnceLock::new();

/// One path's compiled module, empty until the first call for that path
/// has compiled it. The cell's own lock is the single-flight gate: callers
/// for the same path queue on it while one of them compiles.
type Compiled = Mutex<Option<(Engine, Module)>>;

/// Compiles `wasm_path` once per process, however many callers ask at the
/// same time.
///
/// Compiling is the one slow step here (seconds in an unoptimized build,
/// and it takes every core it is given), and the first requests to a
/// freshly booted host all arrive before it finishes. Letting each of
/// them compile its own copy, as an earlier version did, made a burst of
/// cold requests slower than one compile by the size of the burst; on a
/// small machine a client that retried after its own timeout kept adding
/// compiles faster than they finished, and no request was ever answered.
/// So the callers for one path wait on the first one's compile instead,
/// and a compile that fails leaves the cell empty for the next caller to
/// retry. Different paths do not wait on each other.
fn engine_and_module(wasm_path: &Path) -> anyhow::Result<(Engine, Module)> {
    let cache = ENGINE_AND_MODULE.get_or_init(|| Mutex::new(HashMap::new()));
    let cell = Arc::clone(cache.lock().unwrap().entry(wasm_path.to_path_buf()).or_default());

    let mut compiled = cell.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some((engine, module)) = compiled.as_ref() {
        return Ok((engine.clone(), module.clone()));
    }
    let engine = Engine::default();
    let module = Module::from_file(&engine, wasm_path)?;
    #[cfg(test)]
    COMPILED_PATHS.lock().unwrap().push(wasm_path.to_path_buf());
    *compiled = Some((engine.clone(), module.clone()));
    Ok((engine, module))
}

/// Every path `engine_and_module` has compiled, one entry per compile, so
/// a test can tell one compile from a burst of them.
#[cfg(test)]
static COMPILED_PATHS: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// How many times `wasm_path` has been compiled in this process.
#[cfg(test)]
pub(crate) fn compile_count(wasm_path: &Path) -> usize {
    COMPILED_PATHS.lock().unwrap().iter().filter(|compiled| compiled.as_path() == wasm_path).count()
}

/// Compiles `wasm_path` now, so the first request served does not pay for
/// it. The host calls this once at boot, before it starts listening: a
/// client's first read then meets a compiled module rather than a compile
/// longer than its own timeout. Errors when the file is missing or is not
/// a valid module.
pub fn warm(wasm_path: &Path) -> anyhow::Result<()> {
    engine_and_module(wasm_path).map(|_| ())
}

/// Runs `wasm_path` (a wasm32-wasip1 module speaking the `{"steps"}` ->
/// `{"instances","events","refusals"}` CLI contract) against `input`,
/// returning its stdout. The compiled module is cached across calls
/// (see `engine_and_module` above) — `Store`/`Linker`/the instance
/// itself stay fresh every call, so there is still no state to leak
/// between invocations.
pub fn run(wasm_path: &Path, input: &str) -> anyhow::Result<String> {
    let (engine, module) = engine_and_module(wasm_path)?;

    let mut linker: Linker<WasiP1Ctx> = Linker::new(&engine);
    p1::add_to_linker_sync(&mut linker, |ctx| ctx)?;

    let stdout_pipe = MemoryOutputPipe::new(64 * 1024 * 1024);
    let wasi_ctx = WasiCtxBuilder::new()
        .stdin(StepsIn(MemoryInputPipe::new(input.to_string())))
        .stdout(StepsOut(stdout_pipe.clone()))
        .build_p1();

    let mut store = Store::new(&engine, wasi_ctx);
    let instance = linker.instantiate(&mut store, &module)?;
    let start = instance.get_typed_func::<(), ()>(&mut store, "_start")?;

    // A WASI "command" module calls `proc_exit` (surfaced as a trap
    // carrying `I32Exit`) on ordinary completion too, not only on
    // failure — exit code 0 is success, matching how a native process's
    // exit status is read after `main` returns.
    match start.call(&mut store, ()) {
        Ok(()) => {}
        Err(err) => {
            if let Some(exit) = err.downcast_ref::<wasmtime_wasi::I32Exit>() {
                if exit.0 != 0 {
                    anyhow::bail!("wasm module exited with status {}", exit.0);
                }
            } else {
                return Err(err.into());
            }
        }
    }

    drop(store);
    Ok(String::from_utf8(stdout_pipe.contents().to_vec())?)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A copy of the checkout fixture wasm at a path no other test uses, so
    /// its first call is a real cold compile whatever order tests run in.
    pub(crate) fn cold_copy_of_fixture(name: &str) -> PathBuf {
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm");
        let dir = std::env::temp_dir().join(format!("hecks_wasm_runner_{}_{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let copy = dir.join("checkout_fixture.wasm");
        std::fs::copy(&source, &copy).expect("bin/project_wasm writes checkout_fixture.wasm");
        copy
    }

    /// The first requests to a booted host all arrive before its compile
    /// finishes. Each used to compile its own copy, so a burst cost the
    /// burst's size in compiles and, on a small machine, never finished.
    #[test]
    fn a_burst_of_cold_callers_compiles_the_module_once() {
        let path = cold_copy_of_fixture("burst");
        let callers: Vec<_> = (0..8)
            .map(|_| {
                let path = path.clone();
                std::thread::spawn(move || engine_and_module(&path).map(|_| ()))
            })
            .collect();
        for caller in callers {
            caller.join().unwrap().unwrap();
        }
        assert_eq!(compile_count(&path), 1);
    }

    #[test]
    fn a_warmed_module_is_not_compiled_again_by_the_first_run() {
        let path = cold_copy_of_fixture("warm");
        warm(&path).unwrap();
        assert_eq!(compile_count(&path), 1);

        let answer = run(&path, r#"{"steps": []}"#).unwrap();
        assert!(answer.contains("instances"), "got {answer}");
        assert_eq!(compile_count(&path), 1, "run reused the warmed module");
    }

    #[test]
    fn a_module_that_fails_to_compile_is_retried_by_the_next_caller() {
        let path = cold_copy_of_fixture("retry");
        let good = std::fs::read(&path).unwrap();
        std::fs::write(&path, b"not a wasm module").unwrap();
        assert!(warm(&path).is_err());
        assert_eq!(compile_count(&path), 0);

        std::fs::write(&path, good).unwrap();
        warm(&path).unwrap();
        assert_eq!(compile_count(&path), 1);
    }
}
