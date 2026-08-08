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
// (docs/decisions/0012-wasm-via-wasi-stdio.md) — `MemoryInputPipe`/
// `MemoryOutputPipe` (wasmtime_wasi::p2::pipe) are the in-process
// equivalent of piping a string to/from a subprocess, without actually
// spawning one. Neither implements `StdinStream`/`StdoutStream`
// directly in this wasmtime-wasi version, so the two thin wrappers
// below just forward to them — no behavior of their own.

use std::path::Path;
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

/// Runs `wasm_path` (a wasm32-wasip1 module speaking the `{"steps"}` ->
/// `{"instances","events","refusals"}` CLI contract) against `input`,
/// returning its stdout. One fresh `Engine`/`Store`/instance per call —
/// this crate is a Lambda handler, not a long-lived server, so there is
/// no instance pool to manage and no state to leak between invocations
/// (the module's own `Store::new()` inside `kernel::cli::run` already
/// starts empty every call regardless).
pub fn run(wasm_path: &Path, input: &str) -> anyhow::Result<String> {
    let engine = Engine::default();
    let module = Module::from_file(&engine, wasm_path)?;

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
