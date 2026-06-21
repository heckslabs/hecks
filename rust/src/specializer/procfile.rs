//! Overmind `Procfile` + `.overmind.env` emitter — the i262/i276
//! `:overmind` generator capability. Sibling to wrangler_toml (the
//! Cloudflare config emitter) : a per-Mindstream artifact emitter, not an
//! arm in the generic byte-identity `specializer::emit()` dispatch.
//!
//! Reads a Mindstream's `mindstream.fixtures` (the boot Mindstream + its
//! MindstreamMember entries) and emits the two overmind artifacts so they
//! are DERIVED from the bluebook, not hand-synced :
//!
//!   * `Procfile`      — one `name: command` line per MindstreamMember,
//!                       in fixture declaration order. The command line is
//!                       read VERBATIM from the member's
//!                       `command: { line: "…" }` value object — whatever
//!                       the fixture says is what is emitted.
//!   * `.overmind.env`  — `OVERMIND_CAN_DIE` is the comma-separated list of
//!                       every member whose `lifespan: { kind: "one_shot" }`,
//!                       followed by the framework env the boot pipeline
//!                       needs (`HECKS_DAEMON=1`, `HECKS_EVENT_SOURCING=1`).
//!
//! The fixtures are the source of truth ; these files are the artifact.
//! Re-runs against the same fixtures produce byte-identical output. Driven
//! by `storehouse specialize procfile --fixtures <mindstream.fixtures>
//! --output-dir <dir>` (writes both files into the directory).

/// One MindstreamMember projected onto the fields the emitter needs : the
/// Procfile process name, the shell command line, and the lifespan kind
/// that decides OVERMIND_CAN_DIE membership.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct MemberFields {
    pub name: String,
    pub command: String,
    pub lifespan_kind: String,
}

/// Read every `MindstreamMember` fixture out of a `mindstream.fixtures`
/// source string, in declaration order, projecting each onto MemberFields.
///
/// Fixtures use the flat multi-line kwarg form, with `command` and
/// `lifespan` as inline hash literals :
///
/// ```text
/// fixture "heart",
///         name:       "heart",
///         mindstream: "boot",
///         command:    { line: "…storehouse loop … --every 1s" },
///         lifespan:   { kind: "persistent", may_exit: false, … }
/// ```
///
/// Only fixtures inside the `aggregate "MindstreamMember" do` block are
/// collected (the `Mindstream` aggregate's own fixture is skipped). Blank
/// and comment lines between members are tolerated.
pub fn read_members(source: &str) -> Vec<MemberFields> {
    let lines: Vec<&str> = source.lines().collect();
    let mut members = Vec::new();
    let mut in_member_block = false;
    let mut i = 0;
    while i < lines.len() {
        let trimmed = lines[i].trim();
        if trimmed.starts_with("aggregate ") {
            in_member_block = trimmed.contains("\"MindstreamMember\"");
            i += 1;
            continue;
        }
        if in_member_block && trimmed.starts_with("fixture ") {
            // Accumulate this fixture's kwarg lines : the opener plus every
            // following line until the next `fixture`, an `end`, or another
            // `aggregate`. Comments and blanks are folded in (harmless —
            // the per-key extractors ignore non-matching lines).
            let mut block = vec![trimmed.to_string()];
            let mut j = i + 1;
            while j < lines.len() {
                let next = lines[j].trim();
                if next.starts_with("fixture ")
                    || next.starts_with("aggregate ")
                    || next == "end"
                {
                    break;
                }
                block.push(next.to_string());
                j += 1;
            }
            members.push(project(&block));
            i = j;
            continue;
        }
        i += 1;
    }
    members
}

/// Project one fixture's accumulated kwarg lines onto MemberFields. Reads
/// `name:`, the `line:` inside `command: { … }`, and the `kind:` inside
/// `lifespan: { … }`. Order-independent ; missing keys stay empty.
fn project(block: &[String]) -> MemberFields {
    let mut m = MemberFields::default();
    for raw in block {
        let line = raw.trim().trim_end_matches(',');
        if let Some(v) = after_key(line, "name:") {
            if m.name.is_empty() {
                m.name = unquote(v);
            }
        }
        if let Some(v) = after_key(line, "command:") {
            m.command = hash_value(v, "line:");
        }
        if let Some(v) = after_key(line, "lifespan:") {
            m.lifespan_kind = hash_value(v, "kind:");
        }
    }
    m
}

/// Return the slice after `key` when `line` begins with it (ignoring
/// leading whitespace), else None. Anchored at line start so `name:` does
/// not match a `mindstream:` line.
fn after_key<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let l = line.trim_start();
    l.strip_prefix(key).map(|rest| rest.trim())
}

/// Pull a quoted value out of a hash literal `{ inner_key: "value", … }`.
/// Finds `inner_key`, then the first double-quoted span after it. Returns
/// an empty string when the key or its quoted value is absent.
fn hash_value(hash: &str, inner_key: &str) -> String {
    let after = match hash.find(inner_key) {
        Some(pos) => &hash[pos + inner_key.len()..],
        None => return String::new(),
    };
    let start = match after.find('"') {
        Some(p) => p + 1,
        None => return String::new(),
    };
    match after[start..].find('"') {
        Some(end) => after[start..start + end].to_string(),
        None => String::new(),
    }
}

/// Strip surrounding double quotes from a bare `"value"` token.
fn unquote(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}

/// Render the `Procfile` body : a generated-from header, then one
/// `name: command` line per member in declaration order.
pub fn emit_procfile(members: &[MemberFields]) -> String {
    let mut out = String::new();
    out.push_str(&procfile_header());
    for m in members {
        out.push_str(&format!("{}: {}\n", m.name, m.command));
    }
    out
}

/// Render the `.overmind.env` body : a generated-from header, the
/// `OVERMIND_CAN_DIE` list of one_shot members, then the framework env.
pub fn emit_overmind_env(members: &[MemberFields]) -> String {
    let can_die: Vec<&str> = members
        .iter()
        .filter(|m| m.lifespan_kind == "one_shot")
        .map(|m| m.name.as_str())
        .collect();
    let mut out = String::new();
    out.push_str(&env_header());
    out.push_str(&format!("OVERMIND_CAN_DIE={}\n", can_die.join(",")));
    out.push_str("HECKS_DAEMON=1\n");
    out.push_str("HECKS_EVENT_SOURCING=1\n");
    out
}

fn procfile_header() -> String {
    "# Generated artifact — do not hand-edit. Source of truth :\n\
     #   aggregates/framework/mindstream/mindstream.fixtures (the boot Mindstream + members)\n\
     #   aggregates/framework/mindstream/mindstream.bluebook (Mindstream, MindstreamMember types)\n\
     # Regenerate : storehouse specialize procfile \
     --fixtures aggregates/framework/mindstream/mindstream.fixtures --output-dir .\n\
     # One line per MindstreamMember (name: command, verbatim) ; one_shot members\n\
     # flow into OVERMIND_CAN_DIE in the sibling .overmind.env.\n"
        .to_string()
}

fn env_header() -> String {
    "# Generated artifact — do not hand-edit. Source of truth :\n\
     #   aggregates/framework/mindstream/mindstream.fixtures (the boot Mindstream + members)\n\
     # Regenerate : storehouse specialize procfile \
     --fixtures aggregates/framework/mindstream/mindstream.fixtures --output-dir .\n\
     # OVERMIND_CAN_DIE lists every MindstreamMember whose lifespan.kind == \"one_shot\" ;\n\
     # the framework env (HECKS_DAEMON, HECKS_EVENT_SOURCING) is what the boot pipeline needs.\n\n"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"Hecks.fixtures "Mindstream" do
  aggregate "Mindstream" do
    fixture "boot",
            name:        "boot",
            description: "the pipeline",
            directory:   { path: "hecks_conception" }
  end

  aggregate "MindstreamMember" do
    fixture "boot",
            name:       "boot",
            mindstream: "boot",
            command:    { line: "storehouse run boot.bluebook" },
            lifespan:   { kind: "one_shot", may_exit: true, restart_on_failure: false }

    # a comment between members
    fixture "heart",
            name:       "heart",
            mindstream: "boot",
            command:    { line: "storehouse loop body Heart::Heart.Beat --every 1s" },
            lifespan:   { kind: "persistent", may_exit: false, restart_on_failure: true }
  end
end
"#;

    #[test]
    fn reads_only_member_fixtures_in_order() {
        let members = read_members(SAMPLE);
        assert_eq!(members.len(), 2);
        assert_eq!(members[0].name, "boot");
        assert_eq!(members[0].command, "storehouse run boot.bluebook");
        assert_eq!(members[0].lifespan_kind, "one_shot");
        assert_eq!(members[1].name, "heart");
        assert_eq!(
            members[1].command,
            "storehouse loop body Heart::Heart.Beat --every 1s"
        );
        assert_eq!(members[1].lifespan_kind, "persistent");
    }

    #[test]
    fn procfile_one_line_per_member_verbatim() {
        let members = read_members(SAMPLE);
        let proc = emit_procfile(&members);
        assert!(proc.contains("boot: storehouse run boot.bluebook\n"));
        assert!(proc.contains("heart: storehouse loop body Heart::Heart.Beat --every 1s\n"));
    }

    #[test]
    fn env_can_die_lists_only_one_shot_members() {
        let members = read_members(SAMPLE);
        let env = emit_overmind_env(&members);
        assert!(env.contains("OVERMIND_CAN_DIE=boot\n"));
        assert!(env.contains("HECKS_DAEMON=1\n"));
        assert!(env.contains("HECKS_EVENT_SOURCING=1\n"));
    }

    #[test]
    fn member_ordering_preserved() {
        let members = read_members(SAMPLE);
        let names: Vec<&str> = members.iter().map(|m| m.name.as_str()).collect();
        assert_eq!(names, vec!["boot", "heart"]);
    }
}
