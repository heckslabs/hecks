#[derive(Debug, Clone, Default)]
pub struct Hecksagon {
    pub name: String,
    pub framework_kind: Option<String>,
    pub persistence: Option<String>,
    pub persistence_options: Vec<(String, String)>,
    pub io_adapters: Vec<IoAdapter>,
    pub shell_adapters: Vec<ShellAdapter>,
    pub llm_adapters: Vec<LlmAdapter>,
    pub compute_adapters: Vec<ComputeAdapter>,
    pub gates: Vec<Gate>,
    pub subscriptions: Vec<String>,
    pub driven_adapters: Vec<DrivenAdapter>,
    pub driving_adapters: Vec<DrivingAdapter>,
    pub families: Vec<Family>,
    pub adapters: Vec<Adapter>,
    pub bindings: Vec<Binding>,
}

#[derive(Debug, Clone, Default)]
pub struct Family {
    pub name: String,
    pub verb: String,
    pub signal: String,
    pub fields: Vec<FamilyField>,
    pub produces: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct FamilyField {
    pub name: String,
    pub source: String,
}

#[derive(Debug, Clone, Default)]
pub struct Adapter {
    pub name: String,
    pub family: String,
    pub handler: String,
}

#[derive(Debug, Clone, Default)]
pub struct Binding {
    pub aggregate: String,
    pub verb: String,
    pub adapter: String,
    pub role: String,
    pub on: String,
    pub success: String,
    pub failure: String,
}

#[derive(Debug, Clone, Default)]
pub struct DrivingAdapter {
    pub name: String,
    pub handlers: Vec<DrivingHandler>,
}

#[derive(Debug, Clone, Default)]
pub struct DrivingHandler {
    pub kind: String,
    pub arg: String,
    pub dispatches: Vec<DrivenDispatch>,
}

#[derive(Debug, Clone, Default)]
pub struct DrivenAdapter {
    pub name: String,
    pub handlers: Vec<DrivenHandler>,
}

#[derive(Debug, Clone, Default)]
pub struct DrivenHandler {
    pub event_ref: String,
    pub canned: Option<CannedResponse>,
    pub dispatches: Vec<DrivenDispatch>,
    pub runs: Vec<String>,
    pub checks: Vec<CheckLeaf>,
}

#[derive(Debug, Clone, Default)]
pub struct CheckLeaf {
    pub cmd: String,
    pub result_into: String,
}
#[derive(Debug, Clone, Default)]
pub struct CannedResponse {
    pub values: Vec<(String, String)>,
}

#[derive(Debug, Clone, Default)]
pub struct DrivenDispatch {
    pub command: String,
    pub attrs: Vec<(String, String)>,
}

#[derive(Debug, Clone, Default)]
pub struct IoAdapter {
    pub kind: String,
    pub options: Vec<(String, String)>,
    pub on_events: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ShellAdapter {
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    pub output_format: String,
    pub timeout: Option<u64>,
    pub working_dir: Option<String>,
    pub env: Vec<(String, String)>,
    pub ok_exit: i32,
}

impl ShellAdapter {
    pub fn placeholders(&self) -> Vec<String> {
        let mut seen: Vec<String> = Vec::new();
        for arg in &self.args {
            let bytes = arg.as_bytes();
            let mut i = 0;
            while i + 4 <= bytes.len() {
                if bytes[i] == b'{' && bytes[i + 1] == b'{' {
                    if let Some(close) = arg[i + 2..].find("}}") {
                        let name = arg[i + 2..i + 2 + close].to_string();
                        if !seen.contains(&name) {
                            seen.push(name);
                        }
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

#[derive(Debug, Clone, Default)]
pub struct Gate {
    pub aggregate: String,
    pub role: String,
    pub allowed_commands: Vec<String>,
}

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
    pub fn effective_trigger(&self) -> Option<&str> {
        self.trigger_on
            .as_deref()
            .or(self.response_into_target.as_deref())
    }
}

#[derive(Debug, Clone, Default)]
pub struct ComputeAdapter {
    pub name: String,
    pub function_name: String,
    pub trigger_on: Option<String>,
    pub response_into_target: Option<String>,
    pub response_into_attr: Option<String>,
}

impl ComputeAdapter {
    pub fn effective_trigger(&self) -> Option<&str> {
        self.trigger_on
            .as_deref()
            .or(self.response_into_target.as_deref())
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
        self.compute_adapters
            .iter()
            .find(|a| a.name == adapter_name)
    }

    pub fn gate_for(&self, aggregate: &str, role: &str) -> Option<&Gate> {
        self.gates
            .iter()
            .find(|g| g.aggregate == aggregate && g.role == role)
    }

    pub fn persistence_option(&self, key: &str) -> Option<&str> {
        self.persistence_options
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}
