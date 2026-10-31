//! Resolves a bare `correlates_by` name to an aggregate's identity path, once every aggregate
//! exists. `correlates_by Message` means `"Message.id"`; mirrors
//! `BluebookBuilder::Validation#resolve_bare_correlation_keys!` in the Ruby builder.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// Rewrites every bare process-manager key that names an aggregate of `bluebook` to
/// `"<Aggregate>.<identity>"`. A dotted key is left as written; a bare name that names no
/// aggregate is refused with the same message the Ruby builder gives.
pub fn resolve_bare(file: &str, bluebook: &mut ir::Bluebook) -> ParseResult<()> {
    let aggregates = bluebook.aggregates.clone();

    for process_manager in &mut bluebook.process_managers {
        let key = process_manager.correlates_by.clone();
        if key.is_empty() || key.contains('.') {
            continue;
        }

        let bare = key.rsplit("::").next().unwrap_or(&key);
        let Some(aggregate) = aggregates.iter().find(|candidate| candidate.name == bare) else {
            return Err(Diagnostic::new(
                file,
                0,
                bare_correlation_message(&process_manager.name, &key),
            ));
        };

        let identity = identity_path(file, &process_manager.name, aggregate)?;
        process_manager.correlates_by = format!("{}.{identity}", aggregate.name);
    }

    Ok(())
}

/// The one field an aggregate is correlated by: its identity, or `id` when it declares none.
fn identity_path(file: &str, process_manager: &str, aggregate: &ir::Aggregate) -> ParseResult<String> {
    match aggregate.identified_by.as_slice() {
        [] => Ok("id".to_string()),
        [only] => Ok(only.strip_suffix(".value").unwrap_or(only).to_string()),
        [first, ..] => Err(Diagnostic::new(
            file,
            0,
            format!(
                "{process_manager} correlates_by {}, but {} has a composite identity — name the one field, e.g. {}.{first}",
                aggregate.name, aggregate.name, aggregate.name
            ),
        )),
    }
}

/// The refusal for a bare name that names no aggregate, worded as the Ruby builder words it.
pub fn bare_correlation_message(process_manager: &str, key: &str) -> String {
    format!(
        "{process_manager} correlates_by {key}, which names a whole field rather than one of its scalars — \
         say which one, e.g. {key}.value (or name an aggregate of this bluebook, which correlates by its identity)"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn aggregate(name: &str, identified_by: &[&str]) -> ir::Aggregate {
        ir::Aggregate {
            name: name.to_string(),
            identified_by: identified_by.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    }

    fn bluebook_with(aggregates: Vec<ir::Aggregate>, key: &str) -> ir::Bluebook {
        ir::Bluebook {
            aggregates,
            process_managers: vec![ir::ProcessManager {
                name: "ScheduledSend".to_string(),
                correlates_by: key.to_string(),
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn a_bare_aggregate_name_expands_to_its_id() {
        let mut bluebook = bluebook_with(vec![aggregate("Message", &["id"])], "Message");

        resolve_bare("t.bluebook", &mut bluebook).unwrap();

        assert_eq!(bluebook.process_managers[0].correlates_by, "Message.id");
    }

    #[test]
    fn a_bare_aggregate_name_expands_to_the_identity_it_declares() {
        let mut bluebook = bluebook_with(vec![aggregate("Sighting", &["code.value"])], "Sighting");

        resolve_bare("t.bluebook", &mut bluebook).unwrap();

        assert_eq!(bluebook.process_managers[0].correlates_by, "Sighting.code");
    }

    #[test]
    fn a_bare_name_that_is_no_aggregate_is_refused() {
        let mut bluebook = bluebook_with(vec![aggregate("Message", &["id"])], "Status");

        let err = resolve_bare("t.bluebook", &mut bluebook).unwrap_err();

        assert!(err.message.contains("ScheduledSend correlates_by Status, which names a whole field"));
    }

    #[test]
    fn a_dotted_path_is_left_unchanged() {
        let mut bluebook = bluebook_with(vec![aggregate("Message", &["id"])], "Message.id");

        resolve_bare("t.bluebook", &mut bluebook).unwrap();

        assert_eq!(bluebook.process_managers[0].correlates_by, "Message.id");
    }
}
