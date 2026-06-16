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
    /// `adapter :tts, name:, provider:, voice_id:, model:, speed:,
    /// stability:, similarity_boost:, style:, trigger_on:, cache_dir:,
    /// auto_play:` entries. Fire-and-forget (`response_field :none`
    /// per the tts adapter family) — the runtime renders audio via the
    /// resolved provider and does NOT cascade a follow-on command.
    pub tts_adapters: Vec<TtsAdapter>,
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
