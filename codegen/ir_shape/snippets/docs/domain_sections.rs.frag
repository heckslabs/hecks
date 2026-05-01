    /// Capability bluebooks (e.g. status, statusline) declare an ordered
    /// list of `section "Title" do row "label", :field … end` blocks at
    /// the top level. The status runner walks these to render its
    /// dashboard rather than hard-coding section composition in Rust.
    /// Empty for bluebooks that don't declare any.
