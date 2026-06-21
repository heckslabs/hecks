// command_attrs.rs — door-level validation of a dispatched command's attr KEYS.
//
// Purpose : reject an attr key the resolved command does not DECLARE, at the
// dispatch door, BEFORE the runtime silently drops it. The adapter layer only
// ever sees DECLARED attrs (driven_adapter_resolver builds its attr_map from
// declared_attrs), so an undeclared key never reaches the tool. The symptom
// that motivated this : `storehouse … Tools::SearchTool.Grep pattern=x path=/y`
// — `path` is not the declared `search_path`, so it vanished, grep fell back to
// cwd, and the run returned a confidently-wrong empty result with exit 1 ("no
// matches"). The claude_tool dispatcher already errors loudly on a missing
// REQUIRED attr (`missing required attr: pattern`) ; this closes the symmetric
// OPTIONAL-attr blind spot that made the search tools "finicky".
//
// Shared by BOTH dispatch doors so they validate identically : the one-shot
// `dispatch_hecksagon` (main.rs, cold path) and the resident
// `run_serve::handle_request` (warm daemon, the default MCP path).
//
// Usage :
//   if let Some((bad, allowed)) = unknown_command_attr(&rt.domain, command, &attrs) {
//       let hint = nearest_attr(&bad, &allowed);
//       // cold path: eprintln! + process::exit(1)
//       // warm path: return ERROR_SENTINEL json (resident — never exit)
//   }

use std::collections::BTreeSet;

/// Find an attr key the resolved command does not declare.
///
/// Allowed keys = the command's declared attribute names ∪ each reference's
/// snake_case name/target (the `reference_to Pizza` → `pizza=<id>` self-ref
/// form) ∪ the universal `id` fallback (accepted on every command per the
/// self-ref dispatch convention). Unioned across every same-named command so a
/// homonym in another realm can never cause a false reject.
///
/// Returns `(unknown_key, sorted_allowed)` for the FIRST undeclared key, or
/// `None` when the command resolves to no aggregate here (UnknownCommand is
/// reported downstream) or every provided key is declared. `attrs` is the raw
/// provided map keyed by attr name ; values are ignored.
pub fn unknown_command_attr<V>(
    domain: &crate::ir::Domain,
    command: &str,
    attrs: &std::collections::HashMap<String, V>,
) -> Option<(String, Vec<String>)> {
    let (head, cmd_name) = command.rsplit_once('.')?;
    let agg_name = head.rsplit("::").next().unwrap_or(head);
    let mut allowed = BTreeSet::new();
    allowed.insert("id".to_string()); // universal self-ref fallback
    let mut matched = false;
    for agg in domain.aggregates.iter().filter(|a| a.name == agg_name) {
        for cmd in agg.commands.iter().filter(|c| c.name == cmd_name) {
            matched = true;
            // The aggregate's natural primary key is a valid dispatch key : the
            // runtime routes the command to an instance by `attrs[identified_by]`
            // (e.g. Pulse identified_by :name → `name=pulse` selects the instance).
            // It is NOT a command-level attribute, so it must be added explicitly,
            // else a custom identity field (anything but `id`) is falsely rejected.
            if let Some(idf) = &agg.identified_by {
                allowed.insert(idf.clone());
            }
            for a in &cmd.attributes {
                allowed.insert(a.name.clone());
            }
            for r in &cmd.references {
                allowed.insert(crate::util::snake_case(&r.name));
                allowed.insert(crate::util::snake_case(&r.target));
            }
        }
    }
    if !matched {
        return None;
    }
    let unknown = attrs.keys().find(|k| !allowed.contains(k.as_str()))?;
    Some((unknown.clone(), allowed.into_iter().collect()))
}

/// The declared attr whose name CONTAINS (or is contained by) the unknown key
/// — nails the muscle-memory misses (`path`→`search_path`,
/// `command`→`shell_command`, `file`→`file_path`) without a full edit-distance
/// pass. `id` is excluded as a suggestion (it is the universal fallback, never
/// what a caller meant by a typo'd key).
pub fn nearest_attr<'a>(unknown: &str, allowed: &'a [String]) -> Option<&'a String> {
    allowed
        .iter()
        .find(|a| a.as_str() != "id" && (a.contains(unknown) || unknown.contains(a.as_str())))
}

/// One-line dispatch-error message shared by both doors.
pub fn unknown_attr_message(command: &str, bad: &str, allowed: &[String]) -> String {
    let hint = nearest_attr(bad, allowed)
        .map(|s| format!(" Did you mean '{}'?", s))
        .unwrap_or_default();
    format!(
        "'{}' has no attribute '{}'.{} Declared attrs: {}.",
        command,
        bad,
        hint,
        allowed.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    // Built from real parser output so the test exercises the same IR the
    // dispatch door sees — no fragile hand-rolled struct literals.
    const SRC: &str = r#"
Hecks.bluebook "Tools" do
  aggregate "SearchTool" do
    attribute :id, Id
    command "Grep" do
      attribute :id, Id
      attribute :pattern, Pattern
      attribute :search_path, SearchPath
      attribute :description, Description
    end
  end

  aggregate "Pizza" do
    attribute :name, Name
    command "AddTopping" do
      reference_to Pizza
      attribute :name, Name
    end
  end

  aggregate "Pulse" do
    identified_by :name
    attribute :name, String
    attribute :count, Integer
    command "Emit" do
      then_set :count, increment: 1
    end
  end
end
"#;

    fn domain() -> crate::ir::Domain {
        crate::parser::parse(SRC)
    }

    fn pairs(ks: &[(&str, &str)]) -> HashMap<String, String> {
        ks.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn declared_attrs_pass() {
        let d = domain();
        let attrs = pairs(&[("pattern", "x"), ("search_path", "/y"), ("description", "z")]);
        assert_eq!(unknown_command_attr(&d, "Tools::SearchTool.Grep", &attrs), None);
    }

    #[test]
    fn universal_id_always_allowed() {
        let d = domain();
        let attrs = pairs(&[("id", "abc"), ("pattern", "x")]);
        assert_eq!(unknown_command_attr(&d, "Tools::SearchTool.Grep", &attrs), None);
    }

    #[test]
    fn undeclared_path_is_rejected_with_suggestion() {
        let d = domain();
        let attrs = pairs(&[("pattern", "x"), ("path", "/y")]);
        let (bad, allowed) = unknown_command_attr(&d, "Tools::SearchTool.Grep", &attrs).unwrap();
        assert_eq!(bad, "path");
        assert_eq!(nearest_attr(&bad, &allowed), Some(&"search_path".to_string()));
    }

    #[test]
    fn unknown_command_returns_none() {
        let d = domain();
        let attrs = pairs(&[("whatever", "x")]);
        assert_eq!(unknown_command_attr(&d, "Tools::SearchTool.NoSuch", &attrs), None);
    }

    #[test]
    fn reference_snake_target_allowed() {
        let d = domain();
        // `pizza=<id>` (snake_case of the reference target) must be accepted.
        let attrs = pairs(&[("pizza", "id-1"), ("name", "basil")]);
        assert_eq!(unknown_command_attr(&d, "Pizzas::Pizza.AddTopping", &attrs), None);
    }

    #[test]
    fn identity_field_is_allowed() {
        // Pulse is `identified_by :name` ; `name=pulse` selects the instance
        // to Emit on. It is NOT a command attribute, but it is a valid
        // dispatch key — the runtime routes by attrs[identified_by].
        let d = domain();
        let attrs = pairs(&[("name", "pulse")]);
        assert_eq!(unknown_command_attr(&d, "Body::Pulse.Emit", &attrs), None);
    }

    #[test]
    fn message_includes_suggestion_and_declared_list() {
        let d = domain();
        let attrs = pairs(&[("pattern", "x"), ("path", "/y")]);
        let (bad, allowed) = unknown_command_attr(&d, "Tools::SearchTool.Grep", &attrs).unwrap();
        let msg = unknown_attr_message("Tools::SearchTool.Grep", &bad, &allowed);
        assert!(msg.contains("Did you mean 'search_path'?"), "{}", msg);
        assert!(msg.contains("Declared attrs:"), "{}", msg);
    }
}
