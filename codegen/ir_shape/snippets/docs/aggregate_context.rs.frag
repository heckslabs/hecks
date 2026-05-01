    /// Bounded context = the bluebook namespace this aggregate was
    /// declared inside. `Hecks.bluebook "Library"` containing
    /// `aggregate "Inbox"` makes `context = Some("Library")`. Dispatch
    /// addresses an aggregate as `Context.Aggregate.Command` (i142) ;
    /// the same aggregate name in two contexts is two distinct
    /// aggregates, not a collision. Cross-corpus collisions like
    /// Identity (boot/being/first_breath) and Memory
    /// (miette/mind/library) resolve naturally once dispatch carries
    /// the context. Optional during the migration : aggregates from
    /// older code paths or bare-string parsers can still resolve
    /// without a context (legacy `Aggregate.Command` form), but new
    /// code is expected to set it. Closes i134 (context maps), i137
    /// (corpus-wide name collisions), i140 (Identity collision).
