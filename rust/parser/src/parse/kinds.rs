//! Mirror of `Hecks::Bluebook::DSL::Kinds` (lib/hecks/bluebook/dsl/kinds.rb): an aggregate
//! declared `kind: "Run"` is built from the kind's own text, `lib/hecks/language/kinds/run.kind`,
//! with the aggregate's body read at the kind's `# body` line. `{Name}` in the text stands for the
//! aggregate's name and `{Stem}` for that name without the kind.

/// Every kind file, by its file stem. The crate never ships, so the text is read in at build
/// time; `every_kind_file_is_listed` keeps this table and the directory in step.
const KINDS: &[(&str, &str)] = &[(
    "run",
    include_str!("../../../../lib/hecks/language/kinds/run.kind"),
)];

/// The line a kind's body is read at, as Ruby's `/^# body\n/` finds it.
const BODY_MARK: &str = "# body\n";

/// The kind's text before and after its body line, with `{Name}` and `{Stem}` filled in, or
/// `None` when no kind file has that name.
pub fn halves(kind: &str, name: &str) -> Option<(String, String)> {
    let stem = kind.to_lowercase();
    let (_, text) = KINDS.iter().find(|(file, _)| *file == stem)?;
    let (before, after) = split_at_body(text);
    Some((fill(before, name, kind), fill(after, name, kind)))
}

/// Where Ruby says a kind's file would be, for the refusal when there is none.
pub fn path(kind: &str) -> String {
    format!("lib/hecks/language/kinds/{}.kind", kind.to_lowercase())
}

fn split_at_body(text: &str) -> (&str, &str) {
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        if line == BODY_MARK {
            return (&text[..offset], &text[offset + line.len()..]);
        }
        offset += line.len();
    }
    (text, "")
}

fn fill(text: &str, name: &str, kind: &str) -> String {
    let stem = name.strip_suffix(kind).unwrap_or(name);
    text.replace("{Name}", name).replace("{Stem}", stem)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_kind_file_is_listed() {
        let dir = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../lib/hecks/language/kinds"
        );
        let mut on_disk: Vec<String> = std::fs::read_dir(dir)
            .expect("the kinds directory")
            .filter_map(|entry| {
                let name = entry.ok()?.file_name().into_string().ok()?;
                name.strip_suffix(".kind").map(str::to_string)
            })
            .collect();
        on_disk.sort();
        let mut listed: Vec<String> = KINDS.iter().map(|(stem, _)| (*stem).to_string()).collect();
        listed.sort();
        assert_eq!(listed, on_disk);
    }

    #[test]
    fn fills_the_name_and_stem_and_splits_at_the_body_line() {
        let (before, after) = halves("Run", "GateRun").expect("the Run kind");
        assert!(before.contains("attribute :run,       RunKey"));
        assert!(!before.lines().chain(after.lines()).any(|l| l == "# body"));
        assert!(after.contains("reference_to GateRun"));
        assert!(!after.contains("{Name}") && !after.contains("{Stem}"));
    }

    #[test]
    fn an_unknown_kind_has_no_halves() {
        assert_eq!(halves("Walk", "GateWalk"), None);
        assert_eq!(path("Walk"), "lib/hecks/language/kinds/walk.kind");
    }

    #[test]
    fn a_kind_without_a_body_line_puts_all_its_text_before_the_body() {
        assert_eq!(split_at_body("a\nb\n"), ("a\nb\n", ""));
        assert_eq!(split_at_body("a\n# body\nb\n"), ("a\n", "b\n"));
    }
}
