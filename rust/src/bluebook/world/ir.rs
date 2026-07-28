
#[derive(Debug, Default, Clone)]
pub struct World {
    pub name: String,
    pub purpose: Option<String>,
    pub vision: Option<String>,
    pub audience: Option<String>,
    pub realm: Option<String>,
    pub concerns: Vec<Concern>,
    pub configs: Vec<ExtensionConfig>,
    pub servers: Vec<McpServer>,
    pub adapter_bindings: Vec<AdapterBinding>,
}

#[derive(Debug, Default, Clone)]
pub struct McpServer {
    pub name: String,
    pub token_env: Option<String>,
}

#[derive(Debug, Default, Clone)]
pub struct Concern {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Debug, Default, Clone)]
pub struct AdapterBinding {
    pub name: String,
    pub values: Vec<(String, String)>,
}

#[derive(Debug, Default, Clone)]
pub struct ExtensionConfig {
    pub name: String,
    pub values: Vec<(String, String)>,
}

impl World {
    pub fn config_for(&self, name: &str) -> Option<&ExtensionConfig> {
        self.configs.iter().find(|c| c.name == name)
    }

    pub fn persistence_strict(&self) -> bool {
        self.config_for("persistence").and_then(|c| c.get("strict")) == Some("true")
    }

    pub fn door_posture(&self) -> Option<&str> {
        self.config_for("door").and_then(|c| c.get("posture"))
    }

    pub fn server_for(&self, name: &str) -> Option<&McpServer> {
        let want = name.trim_start_matches(':');
        self.servers.iter().find(|s| s.name == want)
    }

    pub fn adapter_binding_for(&self, name: &str) -> Option<&AdapterBinding> {
        self.adapter_bindings.iter().find(|b| b.name == name)
    }
}

impl AdapterBinding {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}

impl ExtensionConfig {
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
    }
}
