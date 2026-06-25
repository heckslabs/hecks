    /// The FOLDER address of the bluebook this aggregate was loaded from —
    /// `realm/context` (e.g. "hecks/language/grammar"), the Realm + Context
    /// segments of `Realm::Context::Bluebook::Aggregate`. Stamped by
    /// `load_combined_domain` from the file path (`heki::folder_address`), NOT
    /// by the string parser — so it is `None` on the parity path (a bare
    /// string, no file) and correctly outside the parser contract. The FQN
    /// resolver matches an address's realm + context against this. `None` for a
    /// string-parsed or pathless aggregate.
