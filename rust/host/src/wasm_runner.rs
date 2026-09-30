// Runs the compiled `.wasm` artifact through an embedded wasmtime
// instance — the only place in this crate that touches wasmtime.

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

// Cached per (warm) process, not per call — `Engine`/`Module` hold only
// the compiled artifact, so caching leaks nothing between invocations.
// Recompiling on every warm call would cost real seconds per dispatch,
// and `dispatch::read`'s snapshot fast path never reaches here at all.
//
// Keyed by `wasm_path`, not one shared slot: a single test binary can
// dispatch against two domains' `.wasm` files at once, and a bare
// `OnceLock<(Engine, Module)>` would silently serve one domain's
// compiled module to the other's dispatch calls.
static ENGINE_AND_MODULE: OnceLock<Mutex<HashMap<PathBuf, Arc<Compiled>>>> = OnceLock::new();

/// One path's compiled module, empty until first compiled. The cell's
/// lock is the single-flight gate other callers for the same path queue on.
type Compiled = Mutex<Option<(Engine, Module)>>;

/// Compiles `wasm_path` once per process, however many callers ask at
/// once — later callers for the same path block on the first one's
/// compile rather than each paying for their own. A failed compile
/// leaves the cell empty for the next caller to retry.
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

/// Compiles `wasm_path` at boot, before the host starts listening, so
/// the first real request meets an already-compiled module.
pub fn warm(wasm_path: &Path) -> anyhow::Result<()> {
    engine_and_module(wasm_path).map(|_| ())
}

/// Runs `wasm_path` (a wasm32-wasip1 module speaking the `{"steps"}` ->
/// `{"instances","events","refusals"}` contract) against `input`,
/// returning its stdout. `Store`/`Linker` are fresh every call.
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

    // A WASI "command" module calls `proc_exit` (an `I32Exit` trap) on
    // ordinary completion too — exit code 0 is success here, same as a
    // native process's exit status after `main` returns.
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
        std::fs::copy(&source, &copy).expect("hecks build_wasm writes checkout_fixture.wasm");
        copy
    }

    /// A burst of concurrent cold callers compiles the module exactly
    /// once; paying per-caller would make a cold burst slower than one
    /// compile and let retries after a timeout pile up faster than they finish.
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
