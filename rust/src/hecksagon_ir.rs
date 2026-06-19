//! Hecksagon IR — Rust mirror of Hecksagon::Structure for .hecksagon files
//! [antibody-exempt: kernel-floor runtime IR for .hecksagon adapters — inherently Rust]//!
//! A .hecksagon declares the adapter wiring around a .bluebook domain:
//! which shell commands are named, which aggregates are gated to which
//! roles, which external domains this one subscribes to, which
//! persistence adapter (memory / heki), and which side-effect adapters
//! (:stdout, :stderr, :stdin, :env, :fs, :shell) are bound.
//!
//! Structure parity with Ruby:
//!   Hecksagon::Structure::Hecksagon         → Hecksagon
//!   Hecksagon::Structure::GateDefinition    → Gate
//!   Hecksagon::Structure::ShellAdapter      → ShellAdapter
//!
//! Only the subset the Rust runtime needs is modeled — extensions,
//! capabilities, tenancy, context_map etc. stay Ruby-only until the
//! runtime grows a reason to honor them.
//!
//! [antibody-exempt: rust/src/hecksagon_ir.rs — kernel-floor IR mirror
//!  of the .hecksagon DSL surface. i228 adds `trigger_on` to LlmAdapter
//!  so the dispatch target that fires the adapter can differ from the
//!  target the response cascades back into ; both halves' parsers must
//!  produce equivalent canonical IR, so the field lives in the kernel
//!  IR struct alongside the existing `response_into_*` pair.
//!
//!  i220 sub-gap 5 (compute-adapter-primitive) adds the
//!  `:compute` adapter family — sibling of `:llm` for local
//!  computation. Where `:llm` adapters call out to a model with a
//!  substituted prompt and chain the response back into a target
//!  command's attribute, `:compute` adapters invoke a named
//!  built-in function (resolved through a registry in
//!  rust/src/runtime/compute_functions/) and chain the computed
//!  string into a target command's attribute. The IR shape mirrors
//!  LlmAdapter (name + trigger_on + response_into_target +
//!  response_into_attr) plus a `function_name` slot for the
//!  registry key.]

/// A .hecksagon file parsed into IR. Name echoes the Ruby class name.
#[derive(Debug, Clone, Default)]
pub struct Hecksagon {
    /// Declared inside `Hecks.hecksagon "Name" do`.
    pub name: String,
    /// Phase 1 of adapter-family activation : files declared with the
    /// new top-level forms (`Hecks.adapter_family` / `Hecks.provider` /
    /// `Hecks.behavior_kind`) carry a meta-layer kind discriminator.
    /// Plain `Hecks.hecksagon "Name" do ... end` files leave this `None`.
    /// The kernel registry walks framework/* and indexes by this field.
    /// Phase 2 will add a richer payload (fields, providers list,
    /// request_body wire shape) so the runtime can drive dispatch.
    pub framework_kind: Option<String>,
    /// `adapter :memory` / `:heki` / `:sqlite` / `:postgres` / `:mysql`
    /// — persistence wiring (the adapter kind as a string). None means
    /// the bluebook's runtime default (memory repository) applies. Only
    /// the kind crosses the Ruby↔Rust canonical-IR parity boundary
    /// (`canonical_ir.rb :: hecksagon_persistence` emits this string) ;
    /// the connection options below stay Rust-runtime-local.
    pub persistence: Option<String>,
    /// Connection options for a SQL persistence kind — e.g. `db:` for
    /// `adapter :sqlite, db: "app.db"`, or `host:`/`user:`/`name:` for
    /// postgres/mysql. Raw key→value pairs lifted off the adapter line,
    /// keyed without the trailing colon. Empty for `:memory` / `:heki`
    /// (which carry no connection target). NOT part of the canonical
    /// parity shape — both parsers route SQL kinds into `persistence`
    /// identically, and the path is a runtime concern, not a contract.
    pub persistence_options: Vec<(String, String)>,
    /// Non-persistence adapter bindings (:stdout, :stderr, :stdin, :env,
    /// :fs) keyed by their symbol name. Each adapter may carry a block
    /// or options hash; serialized here as key/value pairs.
    pub io_adapters: Vec<IoAdapter>,
    /// `adapter :shell, name:, command:, args:, …` entries.
    pub shell_adapters: Vec<ShellAdapter>,
    /// `adapter :llm, name:, prompt_template:, model:, max_tokens:,
    /// response_into:, backend:, …` entries. The Phase 1 IR holds the
    /// declared shape ; Phase 2 wires runtime dispatch into Claude /
    /// Ollama and routes the response into the named command.
    pub llm_adapters: Vec<LlmAdapter>,
    /// i220 sub-gap 5 — `adapter :compute, name:, function:, trigger_on:,
    /// response_into:, attr:` entries. Sibling of `llm_adapters` for
    /// local computation : the runtime resolves `function_name` to a
    /// built-in function (registry in runtime/compute_functions/),
    /// invokes it with the upstream state + dispatch attrs, and chains
    /// the returned string into `response_into_target` under
    /// `response_into_attr`.
    pub compute_adapters: Vec<ComputeAdapter>,
    /// `gate "Aggregate", :role do allow :Cmd end` entries.
    pub gates: Vec<Gate>,
    /// `subscribe "OtherDomain"` — reads a directed edge into the
    /// runtime so cross-domain policy routing can fire.
    pub subscriptions: Vec<String>,
    /// Sprint 14 — `adapter "Name" do ; driven on "Event" do |e|
    /// dispatch "Other.Cmd", k: v ; end ; end` entries. Each adapter
    /// declares one or more event handlers ; each handler runs a
    /// follow-on bluebook dispatch when the named event fires.
    pub driven_adapters: Vec<DrivenAdapter>,
    /// Sprint 14 sibling of `driven_adapters` — `adapter "Name" do ;
    /// driving on <kind> "<arg>" do |signal| ; dispatch "X.Y", k: v ;
    /// end ; end` entries. Where `driven on` subscribes to bus events,
    /// `driving on` subscribes to EXTERNAL triggers (cron tick, HTTP
    /// POST, file watch). v1 implements `kind == "cron"` end-to-end ;
    /// `http_post` and `file_watch` parse but are runtime stubs (see
    /// runtime/driving_adapter_resolver.rs follow-up cards).
    pub driving_adapters: Vec<DrivingAdapter>,
    /// bucket-3 — `Hecks.family "name" do verb "v" ; signal :s ; field :f
    /// end` declarations loaded from `*.family` files. A family names an
    /// impure-boundary PORT : its how-verb, its signal, and the config
    /// field NAMES its adapters carry (values live per-deployment in
    /// `.world`). Each `*.family` file parses to one Hecksagon carrying a
    /// single Family ; the resolver flat-maps across the loaded Vec.
    pub families: Vec<Family>,
    /// bucket-3 — `Hecks.adapter "Name" do family "fam" end` declarations
    /// loaded from `*.adapter` files. The inverted arrow : an adapter
    /// DECLARES the family it implements ; the family never names it.
    /// Each `*.adapter` file parses to one Hecksagon carrying a single
    /// Adapter.
    pub adapters: Vec<Adapter>,
    /// bucket-3 — `Aggregate.verb("Adapter"[, on: "Event"])` hexagon binds
    /// lifted off a `.hecksagon` : the composition line that hangs a
    /// how-verb off an aggregate FQN and names the adapter it resolves
    /// through. reply ports carry no `on` ; effect ports carry the
    /// triggering event. Step 2 PARSES these ; the typed attach checkpoint
    /// (adapter→family→verb) and the dispatch-time consult land in later
    /// bucket-3 steps.
    pub bindings: Vec<Binding>,
}

/// bucket-3 — a `*.family` declaration. A family is an impure-boundary
/// PORT declared once and used across every domain's hexagon : the bind
/// `Aggregate.<verb>(...)` resolves THROUGH it. Names only ; the
/// per-deployment values live in `.world`.
#[derive(Debug, Clone, Default)]
pub struct Family {
    /// Family name — between the quotes after `Hecks.family`.
    pub name: String,
    /// The how-verb the bind hangs off the aggregate FQN (`persisted_by`).
    pub verb: String,
    /// Signal kind verbatim, colon stripped — `reply` / `effect` /
    /// `fulfillment`. Empty when undeclared.
    pub signal: String,
    /// Config FIELDS the family's adapters carry — each a name + a source.
    /// The family's fields ESTABLISH the schema its adapters' `.world` blocks
    /// must conform to. Names + sources only ; the VALUES live in `.world`.
    pub fields: Vec<FamilyField>,
    /// The verdict DATA a conforming handler must emit on stdout (k=v lines)
    /// for this port — the OUTPUT half of the contract, symmetric with
    /// `fields` (the INPUT half it reads from `.world`). Declared once on the
    /// family ; every adapter's handler produces them (payment -> payment_ref).
    /// A conformance test asserts the handler actually emits them. Parsed from
    /// the `produces :name` lines of the `*.family` declaration.
    pub produces: Vec<String>,
}

/// bucket-3 — one config field a family declares. The name a `.world` block
/// keys on, plus where its value comes from (the declaration form sets it) :
///   `field  :timeout_ms`           -> source `direct` : the `.world` value IS the literal.
///   `field  :endpoint, from: :env` -> source `env`    : the `.world` value is an env-var NAME.
///   `secret :token`                -> source `secret` : env-var name, never logged.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FamilyField {
    /// The field name — the `.world` block key matches this EXACTLY.
    pub name: String,
    /// `direct` | `env` | `secret`. Default `direct`.
    pub source: String,
}

/// bucket-3 — a `*.adapter` declaration. The inverted arrow : an adapter
/// DECLARES the family it implements ; the family never names the adapter.
#[derive(Debug, Clone, Default)]
pub struct Adapter {
    /// Adapter name — between the quotes after `Hecks.adapter` (its
    /// IDENTITY, e.g. `Heki` / `Stripe`, never its transport).
    pub name: String,
    /// The family this adapter implements (`persistence` / `payment`).
    pub family: String,
    /// The standalone handler the adapter-host execs for this adapter
    /// (`bin/stripe-handler`). Set on out-of-process adapters (payment,
    /// report) ; empty for in-process persistence adapters (heki /
    /// memory), which the runtime injects directly and never shells out.
    /// Parsed from the `handler "..."` line of the `*.adapter` declaration.
    pub handler: String,
}

/// bucket-3 — one hexagon bind decomposed as `aggregate . verb ( adapter
/// [, on: event] )`. The composition line names verbs, ports, and
/// adapters ; it never names a value (per-deployment values live in
/// `.world`). reply ports leave `on` empty ; effect ports carry the
/// triggering event.
#[derive(Debug, Clone, Default)]
pub struct Binding {
    /// The aggregate FQN the how-verb hangs off (`Pizzas::Order`).
    pub aggregate: String,
    /// The how-verb — the FAMILY the bind resolves through
    /// (`persisted_by` → persistence, `charged_by` → payment).
    pub verb: String,
    /// The adapter the bind names (`Heki` / `Stripe`) — the positional
    /// quoted argument. The typed attach checkpoint (later step) verifies
    /// this adapter's family carries `verb`.
    pub adapter: String,
    /// The triggering event for an effect port (`on: "OrderPlaced"`).
    /// Empty for a reply port, which returns rather than round-trips.
    pub on: String,
    /// The effect-port verdict re-entry commands, named in a `do success
    /// "..." failure "..." end` block on the bind. `success` is dispatched
    /// when the adapter reports success, `failure` on failure. Both empty
    /// for reply / fulfillment binds (no block). The binding is the ONLY
    /// home on the locked surface for these names : the family and adapter
    /// are generic (declared once, used across domains) ; the binding alone
    /// is domain-specific.
    pub success: String,
    pub failure: String,
}

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
