// Runs an adapter compiled to a wasm32-wasip2 component through the shared wasmtime engine.
// The component sits beside `wasm_runner`, which runs core modules; the two share the engine, its
// epoch thread and the limits, and nothing else.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Engine, ResourceLimiter, Store, Trap};
use wasmtime_wasi::p2::pipe::MemoryOutputPipe;
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

use crate::component_imports::{self, Imports};
use crate::wasm_runner::{deadline_ticks, engine, Limits, KERNEL_LIMITS};

/// One run's WASI context, its resource table, the imports that answer the component and the
/// memory cap its store enforces.
pub(crate) struct RunState {
    pub(crate) imports: Arc<dyn Imports>,
    wasi: WasiCtx,
    table: ResourceTable,
    memory_bytes: usize,
    memory_refused: bool,
}

impl WasiView for RunState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.wasi,
            table: &mut self.table,
        }
    }
}

impl ResourceLimiter for RunState {
    fn memory_growing(
        &mut self,
        _current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let allowed = desired <= self.memory_bytes && maximum.is_none_or(|max| desired <= max);
        // Refused, not trapped: the guest sees a failed `memory.grow`, and `run_within` reads
        // this flag to say why the call failed.
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

/// One path's compiled component, empty until first compiled; the cell's lock is the
/// single-flight gate other callers for the same path queue on.
type Compiled = Mutex<Option<Component>>;

static COMPONENTS: OnceLock<Mutex<HashMap<PathBuf, Arc<Compiled>>>> = OnceLock::new();

/// Compiles `path` once per process, however many callers ask at once. A failed compile leaves
/// the cell empty for the next caller to retry.
fn component(path: &Path) -> anyhow::Result<(&'static Engine, Component)> {
    let cache = COMPONENTS.get_or_init(|| Mutex::new(HashMap::new()));
    let cell = Arc::clone(
        cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entry(path.to_path_buf())
            .or_default(),
    );
    let mut compiled = cell
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(component) = compiled.as_ref() {
        return Ok((engine(), component.clone()));
    }
    let component = Component::from_file(engine(), path)?;
    #[cfg(test)]
    #[allow(clippy::unwrap_used)]
    tests::COMPILED_PATHS
        .lock()
        .unwrap()
        .push(path.to_path_buf());
    *compiled = Some(component.clone());
    Ok((engine(), component))
}

/// Compiles `path` at boot, so the first real call meets an already-compiled component.
pub fn warm(path: &Path) -> anyhow::Result<()> {
    component(path).map(|_| ())
}

/// Calls the `echo-time` export of the component at `path`: the host's clock, as the component
/// reports it. The run gets the kernel's limits.
pub fn echo_time(path: &Path) -> anyhow::Result<String> {
    run_within(KERNEL_LIMITS, path, |store, instance| {
        let func = instance.get_typed_func::<(), (String,)>(&mut *store, "echo-time")?;
        Ok(func.call(&mut *store, ())?.0)
    })
}

/// Calls the export `name` of the component at `path`, which takes one string and answers
/// `result<string, string>`, with `imports` answering what the component asks of the host. An
/// `Err` inside the answer is the component's own; an `Err` outside is the run's.
pub fn call_text(
    path: &Path,
    imports: Arc<dyn Imports>,
    name: &str,
    argument: &str,
) -> anyhow::Result<Result<String, String>> {
    run_with(KERNEL_LIMITS, path, imports, |store, instance| {
        let func =
            instance.get_typed_func::<(String,), (Result<String, String>,)>(&mut *store, name)?;
        Ok(func.call(&mut *store, (argument.to_string(),))?.0)
    })
}

/// Runs `call` against the component at `path` with no grant beyond the clock.
fn run_within<T>(
    limits: Limits,
    path: &Path,
    call: impl FnOnce(&mut Store<RunState>, &wasmtime::component::Instance) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    run_with(limits, path, component_imports::none(), call)
}

/// Instantiates the component at `path` with the granted imports and hands the instance to
/// `call`. A call that passes its deadline, its memory cap or its output cap is stopped and
/// answered with an error naming the cap.
fn run_with<T>(
    limits: Limits,
    path: &Path,
    imports: Arc<dyn Imports>,
    call: impl FnOnce(&mut Store<RunState>, &wasmtime::component::Instance) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let (engine, component) = component(path)?;
    let mut linker: Linker<RunState> = Linker::new(engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker)?;
    component_imports::link(&mut linker)?;

    let stdout = MemoryOutputPipe::new(limits.output_bytes);
    let wasi = WasiCtxBuilder::new().stdout(stdout.clone()).build();
    let state = RunState {
        imports,
        wasi,
        table: ResourceTable::new(),
        memory_bytes: limits.memory_bytes,
        memory_refused: false,
    };
    let mut store = Store::new(engine, state);
    store.limiter(|state| state);
    store.set_epoch_deadline(deadline_ticks(limits.deadline));
    let called = linker
        .instantiate(&mut store, &component)
        .map_err(Into::into)
        .and_then(|instance| call(&mut store, &instance));
    let memory_refused = store.data().memory_refused;
    drop(store);

    if stdout.contents().len() >= limits.output_bytes {
        anyhow::bail!(
            "the component's output passed the {} byte output cap",
            limits.output_bytes
        );
    }
    called.map_err(|err| name_the_cap(err, memory_refused, &limits))
}

/// Replaces a trap with the cap that caused it, when one did.
fn name_the_cap(err: anyhow::Error, memory_refused: bool, limits: &Limits) -> anyhow::Error {
    if memory_refused {
        return anyhow::anyhow!(
            "the component needed more than its {} MiB memory cap",
            limits.memory_bytes / (1024 * 1024)
        );
    }
    if err.downcast_ref::<Trap>() == Some(&Trap::Interrupt) {
        return anyhow::anyhow!(
            "the component ran past its {} ms deadline and was stopped",
            limits.deadline.as_millis()
        );
    }
    err
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
    use super::*;
    use std::time::Duration;

    pub(super) static COMPILED_PATHS: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

    const SMALL: Limits = Limits {
        deadline: Duration::from_millis(200),
        memory_bytes: 8 * 1024 * 1024,
        output_bytes: 1024,
    };

    /// A copy of the fixture component at a path no other test uses, so its first call is a real
    /// cold compile whatever order the tests run in.
    fn fixture(name: &str) -> PathBuf {
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../spec/fixtures/wasm_component/clock_echo.wasm");
        let dir = std::env::temp_dir().join(format!(
            "hecks_component_runner_{}_{name}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let copy = dir.join("clock_echo.wasm");
        std::fs::copy(source, &copy).unwrap();
        copy
    }

    fn compile_count(path: &Path) -> usize {
        COMPILED_PATHS
            .lock()
            .unwrap()
            .iter()
            .filter(|p| p.as_path() == path)
            .count()
    }

    #[test]
    fn the_component_reports_the_time_the_host_granted() {
        let path = fixture("echo");
        let before = crate::clock::unix_now();
        let answer = echo_time(&path).unwrap();
        let seconds: i64 = answer.strip_prefix("t=").unwrap().parse().unwrap();
        assert!((before..=before + 5).contains(&seconds), "got {answer}");
    }

    #[test]
    fn a_component_is_compiled_once_per_path() {
        let path = fixture("once");
        warm(&path).unwrap();
        echo_time(&path).unwrap();
        echo_time(&path).unwrap();
        assert_eq!(compile_count(&path), 1);
    }

    #[test]
    fn a_looping_component_is_stopped_at_its_deadline() {
        let path = fixture("spin");
        warm(&path).unwrap();
        let began = std::time::Instant::now();
        let err = run_within(SMALL, &path, |store, instance| {
            let spin = instance.get_typed_func::<(), ()>(&mut *store, "spin")?;
            Ok(spin.call(&mut *store, ())?)
        })
        .unwrap_err()
        .to_string();
        assert!(err.contains("200 ms deadline"), "got {err}");
        assert!(
            began.elapsed() < Duration::from_secs(5),
            "took {:?}",
            began.elapsed()
        );
    }

    fn grow(path: &Path, pages: u32) -> anyhow::Result<u32> {
        run_within(SMALL, path, |store, instance| {
            let grow = instance.get_typed_func::<(u32,), (u32,)>(&mut *store, "grow")?;
            Ok(grow.call(&mut *store, (pages,))?.0)
        })
    }

    #[test]
    fn growth_within_the_memory_cap_is_allowed() {
        assert_eq!(grow(&fixture("grow_ok"), 16).unwrap(), 16);
    }

    #[test]
    fn growth_past_the_memory_cap_is_refused_with_an_error_naming_it() {
        // 8 MiB cap, 256 pages = 16 MiB.
        let err = grow(&fixture("grow_refused"), 256).unwrap_err().to_string();
        assert!(err.contains("8 MiB memory cap"), "got {err}");
    }
}
