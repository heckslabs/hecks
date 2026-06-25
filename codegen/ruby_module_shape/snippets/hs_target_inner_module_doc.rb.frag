    # ---- Shared base for target modules -----------------------------
    #
    # Mixin that gives each target:
    #   #initialize       — loads fixtures from self.class::SHAPE
    #   #by_aggregate     — group helper
    #   #read_snippet_body — delegate to module-level helper
