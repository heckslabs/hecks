    /// Run interactively — the terminal adapter drives the runtime.
    pub fn run_interactive(&mut self) {
        let name = self.domain.name.clone();
        adapter_terminal::run(self, &name);
    }
