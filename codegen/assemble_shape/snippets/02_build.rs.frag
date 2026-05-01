/// Read every declared heki store + on-disk bluebook count + pidfile
/// state into a `Report`. Missing stores yield "—" / 0 values.
pub fn build(info_dir: &str, conception_dir: &Path, _registry: &AdapterRegistry) -> Report {
    let identity      = latest(&load(info_dir, "identity"));
    let consciousness = latest(&load(info_dir, "consciousness"));
    let heartbeat     = latest(&load(info_dir, "heartbeat"));
    let tick          = latest(&load(info_dir, "tick"));
    let mood          = latest(&load(info_dir, "mood"));
    let dream         = latest(&load(info_dir, "dream_state"));
    let conversations = load(info_dir, "conversation");
    let last_turn     = latest(&conversations);
    let musings       = load(info_dir, "musing");
    let signals       = load(info_dir, "signal");
    let synapses      = load(info_dir, "synapse");
    let memories      = load(info_dir, "memory");
    let heart         = latest(&load(info_dir, "heart"));
    let breath        = latest(&load(info_dir, "breath"));
    let ultradian     = latest(&load(info_dir, "ultradian"));
    let circadian     = latest(&load(info_dir, "circadian"));
    let awareness     = latest(&load(info_dir, "awareness"));
    let dream_wishes  = load(info_dir, "dream_wish");

    let sleep_cycle = str_field(&consciousness, "sleep_cycle", "—");
    let sleep_total = str_field(&consciousness, "sleep_total", "—");
    let last_wake_at = str_field(&consciousness, "last_wake_at", "—");

    // Awareness's open_themes is a "|"-separated string today (i98) ;
    // split it for tabular display.
    let open_themes_raw = str_field(&awareness, "inbox_open_themes", "");
    let awareness_open_themes: Vec<String> = open_themes_raw
        .split('|')
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
        .collect();

    // Dream-wish counts split by status.
    let (wishes_unfiled_count, wishes_filed_count, wishes_unfiled_top) = wish_summary(&dream_wishes);

    let daemons = vec![
        daemon_row(info_dir, "mindstream",  ".mindstream.pid"),
        daemon_row(info_dir, "heart",       ".heart.pid"),
        daemon_row(info_dir, "breath",      ".breath.pid"),
        daemon_row(info_dir, "circadian",   ".circadian.pid"),
        daemon_row(info_dir, "ultradian",   ".ultradian.pid"),
        daemon_row(info_dir, "sleep_cycle", ".sleep_cycle.pid"),
    ];

    let recent_commits = recent_commits(conception_dir, 5);

    Report {
        identity_name: first_present(&identity, &["first_words", "name"], "—"),
        pronouns: str_field(&identity, "pronouns", "—"),
        linked_to: str_field(&identity, "linked_to", "—"),
        born_at: first_present(&identity, &["born", "born_at"], "—"),
        age_str: humanize_age_from_born(&first_present(&identity, &["born", "born_at"], "")),

        consciousness_state: str_field(&consciousness, "state", "—"),
        sleep_stage: str_field(&consciousness, "sleep_stage", "—"),
        sleep_progress: format!("{}/{}", sleep_cycle, sleep_total),
        is_lucid: str_field(&consciousness, "is_lucid", "—"),
        last_wake_at: last_wake_at.clone(),
        time_since_wake: humanize_age(&last_wake_at),
        sleep_summary: str_field(&consciousness, "sleep_summary", "—"),

        fatigue: str_field(&heartbeat, "fatigue", "—"),
        fatigue_state: str_field(&heartbeat, "fatigue_state", "—"),
        pulse_rate: str_field(&heartbeat, "pulse_rate", "—"),
        flow_rate: str_field(&heartbeat, "flow_rate", "—"),
        pulses_since_sleep: str_field(&heartbeat, "pulses_since_sleep", "—"),
        cycle: first_present(&tick, &["cycle", "beats"], "0"),

        heart_beats: str_field(&heart, "beat_count", "—"),
        breath_count: str_field(&breath, "breath_count", "—"),
        breath_phase: str_field(&breath, "phase", "—"),
        ultradian_phase: str_field(&ultradian, "phase", "—"),
        ultradian_cycle: str_field(&ultradian, "cycle_count", "—"),
        circadian_segment: str_field(&circadian, "segment", "—"),

        mood_state: str_field(&mood, "current_state", "—"),
        creativity_level: str_field(&mood, "creativity_level", "—"),
        precision_level: str_field(&mood, "precision_level", "—"),

        awareness_carrying: str_field(&awareness, "carrying", "—"),
        awareness_concept: str_field(&awareness, "concept", "—"),
        awareness_age_days: str_field(&awareness, "age_days", "—"),
        awareness_inbox_count: str_field(&awareness, "inbox_count", "—"),
        awareness_unfiled_wishes_count: wishes_unfiled_count.to_string(),
        awareness_open_themes,

        musings_count: musings.len(),
        conversations_count: conversations.len(),
        signals_count: signals.len(),
        synapses_count: synapses.len(),
        memories_count: memories.len(),

        wishes_unfiled_count,
        wishes_filed_count,
        wishes_unfiled_top,

        last_dream_at: first_present(&dream, &["updated_at", "created_at"], "—"),
        last_dream_text: dream_text(&dream),
        last_turn_at: first_present(&last_turn, &["updated_at", "created_at"], "—"),
        last_turn_text: turn_text(&last_turn),

        recent_commits,

        aggregates_count: count_bluebooks(&conception_dir.join("aggregates")),
        capabilities_count: count_bluebooks(&conception_dir.join("capabilities")),

        daemons,
    }
}

