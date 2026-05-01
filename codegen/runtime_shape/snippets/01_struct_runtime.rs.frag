
pub struct Runtime {
    pub domain: Domain,
    pub repositories: HashMap<String, Repository>,
    pub event_bus: EventBus,
    pub policy_engine: PolicyEngine,
    pub projections: Vec<Projection>,
    pub middleware: MiddlewareStack,
    pub data_dir: Option<String>,
}

