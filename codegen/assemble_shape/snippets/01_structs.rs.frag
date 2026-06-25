/// One declared daemon's lifecycle state — pidfile + liveness.
pub struct DaemonRow {
    pub name: String,
    pub pid: Option<u32>,
    pub alive: bool,
}

/// Flat snapshot of every field surfaced on the dashboard. The renderer
/// takes it by reference. Fields are grouped by section ; the order
/// here mirrors the rendering order so the data structure reads as the
/// dashboard's table of contents.
pub struct Report {
    // ---- Identity ----
    pub identity_name: String,
    pub pronouns: String,
    pub linked_to: String,
    pub born_at: String,
    pub age_str: String,

    // ---- Consciousness ----
    pub consciousness_state: String,
    pub sleep_stage: String,
    pub sleep_progress: String,
    pub is_lucid: String,
    pub last_wake_at: String,
    pub time_since_wake: String,
    pub sleep_summary: String,

    // ---- Vitals ----
    pub fatigue: String,
    pub fatigue_state: String,
    pub pulse_rate: String,
    pub flow_rate: String,
    pub pulses_since_sleep: String,
    pub cycle: String,

    // ---- Body cycles ----
    pub heart_beats: String,
    pub breath_count: String,
    pub breath_phase: String,
    pub ultradian_phase: String,
    pub ultradian_cycle: String,
    pub circadian_segment: String,

    // ---- Mood ----
    pub mood_state: String,
    pub creativity_level: String,
    pub precision_level: String,

    // ---- Awareness ----
    pub awareness_carrying: String,
    pub awareness_concept: String,
    pub awareness_age_days: String,
    pub awareness_inbox_count: String,
    pub awareness_unfiled_wishes_count: String,
    pub awareness_open_themes: Vec<String>,

    // ---- Memory ----
    pub musings_count: usize,
    pub conversations_count: usize,
    pub signals_count: usize,
    pub synapses_count: usize,
    pub memories_count: usize,

    // ---- Dream wishes ----
    pub wishes_unfiled_count: usize,
    pub wishes_filed_count: usize,
    pub wishes_unfiled_top: Vec<String>,

    // ---- Recent activity ----
    pub last_dream_at: String,
    pub last_dream_text: String,
    pub last_turn_at: String,
    pub last_turn_text: String,

    // ---- Recent commits ----
    pub recent_commits: Vec<String>,

    // ---- Bluebooks ----
    pub aggregates_count: usize,
    pub capabilities_count: usize,

    // ---- Daemons ----
    pub daemons: Vec<DaemonRow>,
}

