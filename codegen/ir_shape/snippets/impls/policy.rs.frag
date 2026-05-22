    /// gap #1b (adapters-as-bluebook) — `on "Aggregate.Event"` is an
    /// aggregate-qualified subscription : the policy fires ONLY for
    /// events of that name emitted BY that aggregate. The bare form
    /// `on "Event"` matches by name across every aggregate (the
    /// historical, backward-compatible behaviour). The qualifier is
    /// the substring before the first `.` ; absent when the form is
    /// bare. We split on the first `.` so an event name never contains
    /// one (they're PascalCase identifiers, so this is safe).
    pub fn event_qualifier(&self) -> Option<&str> {
        self.on_event.split_once('.').map(|(agg, _)| agg)
    }

    /// The bare event name with any `Aggregate.` qualifier stripped.
    /// Validators + the policy index key on this so a qualified
    /// subscription still resolves against the corpus's emitted-event
    /// set (which carries bare names only).
    pub fn event_name(&self) -> &str {
        match self.on_event.split_once('.') {
            Some((_, ev)) => ev,
            None => self.on_event.as_str(),
        }
    }
