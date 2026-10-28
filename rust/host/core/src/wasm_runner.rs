// Runs the compiled `.wasm` artifact through an embedded wasmtime
// instance — the only place in this crate that touches wasmtime.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use wasmtime::{Config, Engine, Linker, Module, ResourceLimiter, Store, Trap};
use wasmtime_wasi::cli::{IsTerminal, StdinStream, StdoutStream};
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::p2::pipe::{MemoryInputPipe, MemoryOutputPipe};
use wasmtime_wasi::WasiCtxBuilder;

/// What one kernel run may spend. `dispatch::run` holds the shared database client and an open
/// transaction while the kernel runs, so a run that never ends, or that grows without bound, would
/// stall every write the host serves.
#[derive(Clone, Copy, Debug)]
struct Limits {
    deadline: Duration,
    memory_bytes: usize,
    output_bytes: usize,
}

/// The limits every real run gets.
///
/// - `deadline`: the corpus's runs finish in milliseconds, and a world fed in at the 1 GiB memory
///   cap still finishes in about 4 s on an Apple M-series release build, so 10 s leaves room for a
///   slower production core without letting one run hold the database for long.
/// - `memory_bytes`: a run needs roughly five to nine times its output in linear memory, so a world
///   whose answer fits `output_bytes` fits in 1 GiB; a run past it could not have answered anyway.
/// - `output_bytes`: the whole world comes back on stdout, and the host holds it in memory too.
const KERNEL_LIMITS: Limits = Limits {
    deadline: Duration::from_secs(10),
    memory_bytes: 1024 * 1024 * 1024,
    output_bytes: 64 * 1024 * 1024,
};

/// How often the shared engine's epoch advances; a deadline is counted in these ticks, so a run
/// is stopped at most one tick after its deadline.
const EPOCH_TICK: Duration = Duration::from_millis(100);

/// One run's WASI context and the memory cap its store enforces.
struct RunState {
    wasi: WasiP1Ctx,
    memory_bytes: usize,
    memory_refused: bool,
}

impl ResourceLimiter for RunState {
    fn memory_growing(
        &mut self,
        _current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let allowed = desired <= self.memory_bytes && maximum.is_none_or(|max| desired <= max);
        // Refused, not trapped: the guest sees a failed `memory.grow` and aborts, and `run` reads
        // this flag to say why.
        self.memory_refused |= !allowed;
        Ok(allowed)
    }

    fn table_growing(
        &mut self,
        _current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        Ok(maximum.is_none_or(|max| desired <= max))
    }
}

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

/// The one engine every module compiles against, with epoch interruption on so a run can be
/// stopped at its deadline. A background thread advances its epoch every `EPOCH_TICK`.
fn engine() -> &'static Engine {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    ENGINE.get_or_init(|| {
        let mut config = Config::new();
        config.epoch_interruption(true);
        #[allow(clippy::expect_used)] // reason: a default config with epochs on always builds
        let engine = Engine::new(&config).expect("an engine with epoch interruption builds");
        let ticking = engine.clone();
        std::thread::Builder::new()
            .name("wasm-epoch".to_string())
            .spawn(move || loop {
                std::thread::sleep(EPOCH_TICK);
                ticking.increment_epoch();
            })
            .ok();
        engine
    })
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
    let cell = Arc::clone(
        cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(wasm_path.to_path_buf())
            .or_default(),
    );

    let mut compiled = cell
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some((engine, module)) = compiled.as_ref() {
        return Ok((engine.clone(), module.clone()));
    }
    let engine = engine().clone();
    let module = Module::from_file(&engine, wasm_path)?;
    #[cfg(any(test, feature = "test-support"))]
    #[allow(clippy::unwrap_used)]
    COMPILED_PATHS.lock().unwrap().push(wasm_path.to_path_buf());
    *compiled = Some((engine.clone(), module.clone()));
    Ok((engine, module))
}

/// Every path `engine_and_module` has compiled, one entry per compile, so
/// a test can tell one compile from a burst of them.
#[cfg(any(test, feature = "test-support"))]
static COMPILED_PATHS: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// How many times `wasm_path` has been compiled in this process.
#[cfg(any(test, feature = "test-support"))]
#[allow(clippy::unwrap_used)]
pub fn compile_count(wasm_path: &Path) -> usize {
    COMPILED_PATHS
        .lock()
        .unwrap()
        .iter()
        .filter(|compiled| compiled.as_path() == wasm_path)
        .count()
}

/// Compiles `wasm_path` at boot, before the host starts listening, so
/// the first real request meets an already-compiled module.
pub fn warm(wasm_path: &Path) -> anyhow::Result<()> {
    engine_and_module(wasm_path).map(|_| ())
}

/// Runs `wasm_path` (a wasm32-wasip1 module speaking the `{"steps"}` ->
/// `{"instances","events","refusals"}` contract) against `input`,
/// returning its stdout. `Store`/`Linker` are fresh every call.
///
/// A run that passes its deadline, its memory cap or its output cap (`KERNEL_LIMITS`) is stopped
/// and answered with an error naming the cap, never with a truncated world.
pub fn run(wasm_path: &Path, input: &str) -> anyhow::Result<String> {
    run_within(KERNEL_LIMITS, wasm_path, input)
}

fn run_within(limits: Limits, wasm_path: &Path, input: &str) -> anyhow::Result<String> {
    let (engine, module) = engine_and_module(wasm_path)?;

    let mut linker: Linker<RunState> = Linker::new(&engine);
    p1::add_to_linker_sync(&mut linker, |state: &mut RunState| &mut state.wasi)?;

    let stdout_pipe = MemoryOutputPipe::new(limits.output_bytes);
    let wasi = WasiCtxBuilder::new()
        .stdin(StepsIn(MemoryInputPipe::new(input.to_string())))
        .stdout(StepsOut(stdout_pipe.clone()))
        .build_p1();

    let mut store = Store::new(
        &engine,
        RunState {
            wasi,
            memory_bytes: limits.memory_bytes,
            memory_refused: false,
        },
    );
    store.limiter(|state| state);
    store.set_epoch_deadline(deadline_ticks(limits.deadline));
    let started = start(&mut store, &linker, &module, limits.deadline);
    let memory_refused = store.data().memory_refused;
    drop(store);

    let output = stdout_pipe.contents();
    if output.len() >= limits.output_bytes {
        anyhow::bail!(
            "the kernel's answer passed the {} MiB output cap; the world is too large to answer",
            limits.output_bytes / (1024 * 1024)
        );
    }
    if let Err(err) = started {
        if memory_refused {
            anyhow::bail!(
                "the kernel needed more than its {} MiB memory cap",
                limits.memory_bytes / (1024 * 1024)
            );
        }
        return Err(err);
    }
    Ok(String::from_utf8(output.to_vec())?)
}

/// Instantiates `module` and calls its `_start`, which the store stops once `deadline` passes.
fn start(
    store: &mut Store<RunState>,
    linker: &Linker<RunState>,
    module: &Module,
    deadline: Duration,
) -> anyhow::Result<()> {
    let instance = linker.instantiate(&mut *store, module)?;
    let start = instance.get_typed_func::<(), ()>(&mut *store, "_start")?;

    // A WASI "command" module calls `proc_exit` (an `I32Exit` trap) on
    // ordinary completion too — exit code 0 is success here, same as a
    // native process's exit status after `main` returns.
    match start.call(&mut *store, ()) {
        Ok(()) => Ok(()),
        Err(err) => match err.downcast_ref::<wasmtime_wasi::I32Exit>() {
            Some(exit) if exit.0 == 0 => Ok(()),
            Some(exit) => anyhow::bail!("wasm module exited with status {}", exit.0),
            None if err.downcast_ref::<Trap>() == Some(&Trap::Interrupt) => anyhow::bail!(
                "the kernel ran past its {} ms deadline and was stopped",
                deadline.as_millis()
            ),
            None => Err(err.into()),
        },
    }
}

/// `deadline` in whole epoch ticks, rounded up so a deadline shorter than one tick still runs.
fn deadline_ticks(deadline: Duration) -> u64 {
    let ticks = deadline.as_nanos().div_ceil(EPOCH_TICK.as_nanos());
    u64::try_from(ticks).unwrap_or(u64::MAX).max(1)
}

#[cfg(any(test, feature = "test-support"))]
pub mod tests {
    #![allow(
        dead_code,
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::wildcard_imports
    )]
    use super::*;

    /// A copy of the checkout fixture wasm at a path no other test uses, so
    /// its first call is a real cold compile whatever order tests run in.
    pub fn cold_copy_of_fixture(name: &str) -> PathBuf {
        let source =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../dist/checkout_fixture.wasm");
        let dir =
            std::env::temp_dir().join(format!("hecks_wasm_runner_{}_{name}", std::process::id()));
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

    /// A `.wat` module written to a path no other test uses, so the module cache never serves
    /// one test's module to another.
    fn wat_module(name: &str, wat: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("hecks_wasm_runner_{}_{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("module.wat");
        std::fs::write(&path, wat).unwrap();
        path
    }

    const SMALL: Limits = Limits {
        deadline: Duration::from_millis(200),
        memory_bytes: 1024 * 1024,
        output_bytes: 16,
    };

    #[test]
    fn a_run_past_its_deadline_is_stopped_with_an_error_naming_it() {
        let path = wat_module(
            "spin",
            r#"(module (memory (export "memory") 1) (func (export "_start") (loop br 0)))"#,
        );
        // Compile first: a cold engine on a loaded runner takes seconds, and that is not the
        // time the deadline bounds.
        warm(&path).unwrap();
        let began = std::time::Instant::now();
        let err = run_within(SMALL, &path, "").unwrap_err().to_string();
        assert!(err.contains("200 ms deadline"), "got {err}");
        // A spin the deadline did not stop would never return, so this bound only has to be
        // loose enough for a CI runner whose cores the cold-compile tests beside this one hold.
        assert!(
            began.elapsed() < Duration::from_secs(30),
            "took {:?}",
            began.elapsed()
        );
    }

    #[test]
    fn a_run_that_grows_past_its_memory_cap_is_refused_with_an_error_naming_it() {
        let path = wat_module(
            "grow",
            r#"(module (memory (export "memory") 1)
                 (func (export "_start")
                   (if (i32.eq (memory.grow (i32.const 100)) (i32.const -1)) (then unreachable))))"#,
        );
        let err = run_within(SMALL, &path, "").unwrap_err().to_string();
        assert!(err.contains("1 MiB memory cap"), "got {err}");
    }

    #[test]
    fn an_answer_past_the_output_cap_is_an_error_not_a_truncated_world() {
        let path = wat_module(
            "chatty",
            r#"(module
                 (import "wasi_snapshot_preview1" "fd_write"
                   (func $fd_write (param i32 i32 i32 i32) (result i32)))
                 (memory (export "memory") 1)
                 (data (i32.const 0) "\08\00\00\00\20\00\00\00")
                 (data (i32.const 8) "{\"instances\": {}, \"events\": []}")
                 (func (export "_start")
                   (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 64)))))"#,
        );
        let err = run_within(SMALL, &path, "").unwrap_err().to_string();
        assert!(err.contains("output cap"), "got {err}");
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
