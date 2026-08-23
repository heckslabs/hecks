// THE SANDBOX BOUNDARY — runs the compiled `.wasm` artifact (built by
// bin/project_wasm, the exact same wasm32-wasip1 module
// bin/rust_conformance's own WASM mode already verifies byte-for-byte
// against native) through an embedded wasmtime instance. This is the
// ONLY place in rust/host that touches wasmtime; everything else (the
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
use std::sync::{Mutex, OnceLock};
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

// COMPILED ONCE PER (warm) LAMBDA EXECUTION ENVIRONMENT, not once per
// CALL — `Engine`/`Module` hold only the compiled artifact, no
// per-invocation state at all (that lives entirely in `Store`, still
// created fresh below, every call), so caching them leaks nothing
// between invocations. This used to be a real, live cost: every
// COMMAND dispatch (`dispatch::handle`) runs through here, and
// `Module::from_file` is wasmtime doing real JIT compilation from raw
// bytes — a genuine multi-second cost on Lambda's own CPU allocation,
// paid again on every single warm call, not just a true cold start.
// `dispatch::read`'s own fast path (a snapshot with nothing to
// replay) never reaches this function at all, which is why reads
// stayed fast while every command got slower than the actual
// rehydrate-replay work here ever needed to be.
//
// KEYED BY `wasm_path`, NOT A BARE SINGLE SLOT — a deployed Lambda's own
// `HECKS_WASM_PATH` never changes across its whole warm lifetime, which
// is exactly why the original single-slot `OnceLock<(Engine, Module)>`
// stayed invisible in production: EVERY call in that process really was
// the same path, forever. FOUND LIVE, in this crate's own `cargo test`:
// one test binary genuinely dispatches against TWO different domains'
// `.wasm` files in the same process (dispatch.rs's own banking.wasm
// fixtures alongside web.rs's lifeadelics.wasm ones, run concurrently
// by cargo test's own thread pool) — whichever path happened to compile
// FIRST silently won for every subsequent call regardless of its own
// `wasm_path` argument, so a banking dispatch got lifeadelics' compiled
// module back and refused every real Banking verb as "unknown command."
// `Engine`/`Module` are both cheap-`Clone` (wasmtime's own docs: each
// wraps an `Arc` internally), so caching owned clones per path costs
// nothing beyond the HashMap entry itself.
static ENGINE_AND_MODULE: OnceLock<Mutex<HashMap<PathBuf, (Engine, Module)>>> = OnceLock::new();

fn engine_and_module(wasm_path: &Path) -> anyhow::Result<(Engine, Module)> {
    let cache = ENGINE_AND_MODULE.get_or_init(|| Mutex::new(HashMap::new()));

    if let Some((engine, module)) = cache.lock().unwrap().get(wasm_path) {
        return Ok((engine.clone(), module.clone()));
    }

    let engine = Engine::default();
    let module = Module::from_file(&engine, wasm_path)?;
    // A LOST RACE IS HARMLESS, NOT WASTED WORK TO AVOID — two calls for
    // the SAME new path, both missing the check above, would each
    // compile once; `entry(...).or_insert_with` just keeps whichever
    // one gets the lock first and drops the other's Engine/Module,
    // same "simpler and just as correct as coordinating who compiles"
    // reasoning the original single-slot version already held to.
    let mut cache = cache.lock().unwrap();
    let entry = cache.entry(wasm_path.to_path_buf()).or_insert_with(|| (engine, module));
    Ok((entry.0.clone(), entry.1.clone()))
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
