
pub struct Runtime {
    pub domain: Domain,
    pub repositories: HashMap<String, Repository>,
    pub event_bus: EventBus,
    pub policy_engine: PolicyEngine,
    pub pm_engine: PMEngine,
    pub projections: Vec<Projection>,
    pub middleware: MiddlewareStack,
    pub data_dir: Option<String>,
    /// i221 — every hecksagon loaded alongside the domain. The
    /// `drain_policies` hook scans these for `:llm` adapters whose
    /// `response_into_target` matches a recently-dispatched command,
    /// substitutes the prompt template, calls the resolved provider,
    /// and dispatches the response back into the named target. Empty
    /// when the runtime is booted via the legacy `Runtime::boot(domain)`
    /// (no hecksagons known) — preserves backward compat with every
    /// existing caller that didn't carry hecksagons.
    pub hecksagons: Vec<Hecksagon>,
    /// i221 — provider registry keyed by backend name (`"test"`,
    /// `"claude"`, `"ollama"`). When empty (default), only the `:test`
    /// backend is implicitly available — claude/ollama require an
    /// explicit `register_llm_provider` call so unit tests can never
    /// silently shell out to a real model.
    pub llm_providers: HashMap<String, Box<dyn llm_providers::LlmProvider>>,
    /// i557 part 1 — Phase-2 framework registry. Populated at boot by
    /// `boot_with_framework_dir` (walks
    /// `<framework_dir>/adapter_families/*.hecksagon` +
    /// `<framework_dir>/behavior_kinds/*.hecksagon`) and seeded with
    /// the kernel hooks the runtime knows natively (today : just
    /// `invoke_claude_tool`). Default-constructed (empty + seeded
    /// hooks) when the runtime boots without a framework path —
    /// preserves backward compat with every caller that doesn't
    /// supply one. Read only by part 2 ; `Runtime::dispatch` still
    /// uses the hardcoded `:claude_tool` path in part 1.
    pub framework_registry: framework_registry::FrameworkRegistry,
}

