    /// Block grammars — declarative keyword routing for the parser
    /// itself (i218). Each entry declares an ordered list of
    /// (keyword, parser_name) pairs. The parser walks a registry built
    /// from this IR rather than a hardcoded if-chain. Empty for
    /// bluebooks that don't declare grammar surface.
