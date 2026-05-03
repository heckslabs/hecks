/// One on-event handler within a process manager. The transition is
/// always single-entry (validated Ruby-side) ; we surface from→to as
/// two named fields rather than a one-key map so the canonical JSON
/// shape is unambiguous.
