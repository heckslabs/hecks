//! Hecksagon IR — Rust mirror of Hecksagon::Structure for .hecksagon files
//!
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

/// A .hecksagon file parsed into IR. Name echoes the Ruby class name.
#[derive(Debug, Default)]
pub struct Hecksagon {
    /// Declared inside `Hecks.hecksagon "Name" do`.
    pub name: String,
    /// `adapter :memory` or `adapter :heki` — persistence wiring. None
    /// means the bluebook's runtime default (memory repository) applies.
    pub persistence: Option<String>,
    /// Non-persistence adapter bindings (:stdout, :stderr, :stdin, :env,
    /// :fs) keyed by their symbol name. Each adapter may carry a block
    /// or options hash; serialized here as key/value pairs.
    pub io_adapters: Vec<IoAdapter>,
    /// `adapter :shell, name:, command:, args:, …` entries.
    pub shell_adapters: Vec<ShellAdapter>,
    /// `gate "Aggregate", :role do allow :Cmd end` entries.
    pub gates: Vec<Gate>,
    /// `subscribe "OtherDomain"` — reads a directed edge into the
    /// runtime so cross-domain policy routing can fire.
    pub subscriptions: Vec<String>,
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

impl Hecksagon {
    pub fn shell_adapter(&self, adapter_name: &str) -> Option<&ShellAdapter> {
        self.shell_adapters.iter().find(|a| a.name == adapter_name)
    }

    pub fn io_adapter(&self, kind: &str) -> Option<&IoAdapter> {
        self.io_adapters.iter().find(|a| a.kind == kind)
    }

    pub fn gate_for(&self, aggregate: &str, role: &str) -> Option<&Gate> {
        self.gates.iter().find(|g| g.aggregate == aggregate && g.role == role)
    }
}
