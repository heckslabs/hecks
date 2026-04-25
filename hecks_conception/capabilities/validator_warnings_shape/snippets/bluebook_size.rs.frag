// Snippet: bluebook_size body — structural-density count, threshold 50.
// Referenced by the `BluebookSizeWarning` fixture's snippet_path. The
// specializer interpolates this directly as the function body between
// the opening `{` and closing `}`.
//
// Rationale (Chris, 2026-04-25) : a large bluebook is a signal to ask
// 'is this really one concern, or is it two ?'. Counts structural
// units rather than literal source lines so the metric tracks
// maintenance load (declarations) rather than source density (which
// can be dominated by doc comments). Each aggregate, attribute on
// aggregate or command, command, policy, and lifecycle transition
// counts as one unit. Threshold 50 ≈ Chris's historical 200-line
// rule from the Ruby project, expressed in declarations.
//
// IR-pure : reads only what's already in `domain` — no source-file
// access, no parser reach-around. Same style as the existing
// validator rules.
    let mut units = domain.aggregates.len();
    for agg in &domain.aggregates {
        units += agg.attributes.len();
        units += agg.commands.len();
        for cmd in &agg.commands {
            units += cmd.attributes.len();
        }
        if let Some(lc) = &agg.lifecycle {
            units += lc.transitions.len();
        }
    }
    units += domain.policies.len();
    if units > 50 {
        Some(format!(
            "⚠ bluebook '{}' has {} structural units (aggregates + attributes + commands + policies + transitions) — is this really one concern, or is it two ?",
            domain.name, units
        ))
    } else {
        None
    }
