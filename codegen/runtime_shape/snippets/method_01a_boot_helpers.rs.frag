    /// i221 — boot with hecksagons attached so the LLM dispatcher's
    /// `drain_policies` hook can resolve `:llm` adapters whose
    /// `response_into_target` references a freshly-dispatched command.
    pub fn boot_with_hecksagons(
        domain: Domain,
        data_dir: Option<String>,
        hecksagons: Vec<Hecksagon>,
    ) -> Self {
        let mut rt = Self::boot_with_data_dir(domain, data_dir);
        rt.hecksagons = hecksagons;
        rt
    }

    /// i221 — register an LLM provider under a backend name. Lets the
    /// caller wire `:claude` / `:ollama` (or test doubles) without
    /// touching the dispatcher. Idempotent on the key.
    pub fn register_llm_provider(
        &mut self,
        backend: impl Into<String>,
        provider: Box<dyn llm_providers::LlmProvider>,
    ) {
        self.llm_providers.insert(backend.into(), provider);
    }

