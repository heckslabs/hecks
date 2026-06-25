/// Sprint 14 sibling of `DrivenAdapter` — externally-triggered adapter
/// declared in `<bluebook>/hecksagons/<service>.hecksagon` as :
///
/// ```text
/// adapter "Name" do
///   driving on cron "*/5 * * * *" do |signal|
///     dispatch "Context::Aggregate.Command", attr: "value"
///   end
/// end
/// ```
///
/// Each handler binds one external trigger → one follow-on dispatch.
/// The runtime's `fire_driving_cron_ticks` (and future `http_post` /
/// `file_watch` resolvers) fire the dispatch when the trigger fires.
#[derive(Debug, Clone, Default)]
pub struct DrivingAdapter {
    /// Adapter name (between the quotes after `adapter`).
    pub name: String,
    /// One handler per `driving on <kind> "<arg>" do |s| ... end` block.
    pub handlers: Vec<DrivingHandler>,
}

/// One `driving on <kind> "<arg>" do |signal| dispatch "X.Y", k: v end`
/// block.
#[derive(Debug, Clone, Default)]
pub struct DrivingHandler {
    /// Trigger kind verbatim — `"cron"`, `"http_post"`, `"file_watch"`.
    /// The resolver dispatches on this string ; unknown kinds are no-ops.
    pub kind: String,
    /// Trigger argument verbatim — a cron expression like `"*/5 * * * *"`,
    /// a URL path like `"/webhooks/stripe"`, a filesystem path like
    /// `"/tmp/inbox/*.json"`. Stored verbatim so each resolver can parse
    /// it per its own grammar.
    pub arg: String,
    /// Follow-on dispatches declared inside the handler body. Reuses
    /// `DrivenDispatch` — the dispatch line shape is identical to the
    /// `driven on` form.
    pub dispatches: Vec<DrivenDispatch>,
}

/// Sprint 14 first-adapter slice — event-subscribed adapter declared
/// in `<bluebook>/hecksagons/<service>.hecksagon` as :
///
/// ```text
/// adapter "Name" do
///   driven on "Context::Aggregate.Event" do |event|
///     dispatch "Context::Aggregate.Command", attr: "value"
///   end
/// end
/// ```
///
/// Each handler binds one event → one follow-on dispatch. The runtime's
/// `resolve_driven_adapters` fires the dispatch when the named event
/// appears on the bus.
#[derive(Debug, Clone, Default)]
pub struct DrivenAdapter {
    /// Adapter name (between the quotes after `adapter`).
    pub name: String,
    /// One handler per `driven on "..." do |e| ... end` block.
    pub handlers: Vec<DrivenHandler>,
}

/// One `driven on "Event" do |e| dispatch "X.Y", k: v end` block.
#[derive(Debug, Clone, Default)]
pub struct DrivenHandler {
    /// Full event reference as declared, e.g. "Tools::ShellTool.BashRan".
    /// Stored verbatim so the resolver can split context/aggregate/event
    /// at match time.
    pub event_ref: String,
    /// Sprint 14 memory-canned-defaults — optional `canned do ... end`
    /// block declared inside the handler body. The canned values stand
    /// in for the wrapped call's return when no `.world` adapter entry
    /// binds this adapter to a real backend ; the resolver merges them
    /// into the follow-on dispatch's attrs (declared dispatch attrs
    /// win on conflict). When a `.world` adapter binding IS present,
    /// the world binding's values take the canned slot instead — same
    /// merge code path, different source. Presence of a `.world` adapter
    /// entry IS the signal ; there is no `backend:` flag.
    pub canned: Option<CannedResponse>,
    /// Follow-on dispatches declared inside the handler body. Each is
    /// a `(command_fqn, attrs)` pair.
    pub dispatches: Vec<DrivenDispatch>,
    /// In-process external commands to run when this handler fires
    /// (e.g. `run "git worktree add {worktree_path}"`). {field} tokens
    /// interpolate from the triggering event. Spawned by the resolver ;
    /// no bin script, no canned. Identity/event fields only — never FK refs.
    pub runs: Vec<String>,
    /// Live-check leaves : `run "cmd", result_into: "Cmd"` — spawned in-process,
    /// arm the flag with ok=(exit==0). No FK ; no bin script.
    pub checks: Vec<CheckLeaf>,}

/// A `run "<cmd>", result_into: "<Command>"` leaf — a live check. The
/// runtime spawns <cmd> in-process and dispatches <Command> with
/// ok=(exit==0). Replaces bin/check-* with an inline adapter declaration.
#[derive(Debug, Clone, Default)]
pub struct CheckLeaf {
    pub cmd: String,
    pub result_into: String,
}
/// Sprint 14 memory-canned-defaults — the wrapped-call return declared
/// inline as :
///
/// ```text
/// driven on "X" do |e|
///   canned do
///     output "ack"
///     exit_code 0
///   end
///   dispatch "Y", attr: "value"
/// end
/// ```
///
/// Stored as ordered key/value pairs (values keep their source-token
/// form — quoted strings retain their quotes, ints stay as digit
/// strings — so `build_attr_map` in the resolver applies the same
/// conversion rule the dispatch attrs already use).
#[derive(Debug, Clone, Default)]
pub struct CannedResponse {
    pub values: Vec<(String, String)>,
}

/// One `dispatch "Context::Aggregate.Command", k: v, k2: v2` line.
#[derive(Debug, Clone, Default)]
pub struct DrivenDispatch {
    /// Full command FQN, e.g. "Tools::TaskTool.Get".
    pub command: String,
    /// Static attribute pairs declared on the dispatch line. Values are
    /// the source-token form (strings still carry surrounding quotes,
    /// integers stay as digit strings) so the resolver can convert
    /// per-attr at fire time.
    pub attrs: Vec<(String, String)>,
    /// i221-C (where-fan-out) — when `Some`, this driven dispatch is a
    /// SWEEP : the resolver runs the named query (filtered by the event
    /// via the spec's query_inputs interpolated against it) and fires the
    /// command once per matching record, with `{record_field}` available
    /// to the dispatch attrs. `None` is the back-compat single dispatch.
    pub for_each: Option<crate::ir::ForEachSpec>,
}

/// :stdout / :stderr / :stdin / :env / :fs adapters. Carries whatever
/// options the parser extracts. The runtime decides what each one means.
#[derive(Debug, Clone, Default)]
pub struct IoAdapter {
    /// `:stdout`, `:stderr`, `:stdin`, `:env`, `:fs`, etc. (stored without
    /// the leading colon).
    pub kind: String,
    /// Options hash from inline form or block body. Values are raw
    /// strings; the runtime interprets them.
    pub options: Vec<(String, String)>,
    /// Optional `on :Event do … end` hooks inside the adapter block.
    /// Lists the event names the adapter cares about. The runtime uses
    /// these as policy-style triggers.
    pub on_events: Vec<String>,
}

/// Mirror of Hecksagon::Structure::ShellAdapter. Execution semantics live
/// in the runtime's ShellDispatcher (see runtime/shell_dispatcher.rs).
#[derive(Debug, Clone, Default)]
pub struct ShellAdapter {
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    /// One of: "text", "lines", "json", "json_lines", "exit_code".
    pub output_format: String,
    pub timeout: Option<u64>,
    pub working_dir: Option<String>,
    pub env: Vec<(String, String)>,
    /// Expected success exit code (0 unless overridden). Non-zero is
    /// still treated as success when `output_format == "exit_code"`.
    pub ok_exit: i32,
}

impl ShellAdapter {
    /// Unique placeholder names referenced by `args`, in first-appearance
    /// order. Mirrors Ruby's `ShellAdapter#placeholders`.
    pub fn placeholders(&self) -> Vec<String> {
        let mut seen: Vec<String> = Vec::new();
        for arg in &self.args {
            let bytes = arg.as_bytes();
            let mut i = 0;
            while i + 4 <= bytes.len() {
                if bytes[i] == b'{' && bytes[i + 1] == b'{' {
                    if let Some(close) = arg[i + 2..].find("}}") {
                        let name = arg[i + 2..i + 2 + close].to_string();
                        if !seen.contains(&name) { seen.push(name); }
                        i += 2 + close + 2;
                        continue;
                    }
                }
                i += 1;
            }
        }
        seen
    }
}

/// `gate "Aggregate", :role do allow :Cmd, :Cmd2 end`
#[derive(Debug, Clone, Default)]
pub struct Gate {
    pub aggregate: String,
    pub role: String,
    pub allowed_commands: Vec<String>,
}

/// Mirror of Hecksagon::Structure::LlmAdapter. Holds the prompt
/// template (with {{placeholder}} tokens), model identifier,
/// max_tokens budget, optional `trigger_on` ("Aggregate.Command"
/// path that fires the adapter — defaults to `response_into_target`
/// when absent), response routing target ("Aggregate.Command" path +
/// the receiving attribute name), and optional backend (:claude /
/// :ollama / :fixture).
///
/// i228 — `trigger_on` lets the dispatch target that fires the adapter
/// differ from the target the response cascades back into. Common case
/// (PM cascade dispatches `Dream.ProduceImage` ; the response carries
/// text into `Dream.RecordImage`) needs the two to differ. When
/// omitted, the runtime falls back to `response_into_target` so
/// existing adapters stay self-triggering.
#[derive(Debug, Clone, Default)]
pub struct LlmAdapter {
    pub name: String,
    pub prompt_template: String,
    pub model: Option<String>,
    pub max_tokens: Option<u64>,
    pub trigger_on: Option<String>,
    pub response_into_target: Option<String>,
    pub response_into_attr: Option<String>,
    pub backend: Option<String>,
}

impl LlmAdapter {
    /// Effective trigger target. `trigger_on` when set ; otherwise
    /// `response_into_target` (the historical default that kept
    /// trigger and response identical).
    pub fn effective_trigger(&self) -> Option<&str> {
        self.trigger_on.as_deref().or(self.response_into_target.as_deref())
    }
}

/// i220 sub-gap 5 — sibling of `LlmAdapter` for local computation.
/// Where `:llm` substitutes a prompt and chains the model's response,
/// `:compute` calls a named built-in function (resolved through
/// `runtime/compute_functions`) and chains the returned string into
/// `response_into_target` under `response_into_attr`.
///
///   adapter :compute, name: :recent_musings_summary do
///     function "summarize_recent_musings"
///     trigger_on "MusingMint.RequestMint"
///     response_into "MusingMint.MintMusing", attr: :recent_musings_summary
///   end
///
/// Same `effective_trigger` fallback semantics as `LlmAdapter` —
/// when `trigger_on` is absent the runtime treats `response_into_target`
/// as the firing target.
#[derive(Debug, Clone, Default)]
pub struct ComputeAdapter {
    pub name: String,
    pub function_name: String,
    pub trigger_on: Option<String>,
    pub response_into_target: Option<String>,
    pub response_into_attr: Option<String>,
}

impl ComputeAdapter {
    /// Effective trigger target. `trigger_on` when set ; otherwise
    /// `response_into_target` (matches LlmAdapter's fallback so the
    /// historical self-triggering shape works without per-adapter
    /// declaration).
    pub fn effective_trigger(&self) -> Option<&str> {
        self.trigger_on.as_deref().or(self.response_into_target.as_deref())
    }
}

impl Hecksagon {
    pub fn shell_adapter(&self, adapter_name: &str) -> Option<&ShellAdapter> {
        self.shell_adapters.iter().find(|a| a.name == adapter_name)
    }

    pub fn io_adapter(&self, kind: &str) -> Option<&IoAdapter> {
        self.io_adapters.iter().find(|a| a.kind == kind)
    }

    pub fn llm_adapter(&self, adapter_name: &str) -> Option<&LlmAdapter> {
        self.llm_adapters.iter().find(|a| a.name == adapter_name)
    }

    pub fn compute_adapter(&self, adapter_name: &str) -> Option<&ComputeAdapter> {
        self.compute_adapters.iter().find(|a| a.name == adapter_name)
    }

    pub fn gate_for(&self, aggregate: &str, role: &str) -> Option<&Gate> {
        self.gates.iter().find(|g| g.aggregate == aggregate && g.role == role)
    }

    /// Look up a persistence connection option by key (without the
    /// trailing colon) — e.g. `persistence_option("db")` for the
    /// `adapter :sqlite, db: "app.db"` path. Returns None when the key
    /// wasn't declared or the persistence kind carries no options.
    pub fn persistence_option(&self, key: &str) -> Option<&str> {
        self.persistence_options
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}
