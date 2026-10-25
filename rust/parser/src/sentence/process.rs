//! A process manager in sentences: what it follows, when it starts and ends, and each step it takes
//! when an event is announced, with the commands it tells aggregates to run and what undoes them.
//!
//! ```text
//! Process: Settlement
//!   It is matched up by reference.value
//!   It starts when TransferRequested is announced
//!   It ends when TransferSettled is announced
//!
//!   When TransferRequested is announced and it is requested, it moves to requested
//!     Then the account is told to debit with number from the source, amount from the amount
//!     If that is refused, the account is told to credit with number from the source
//! ```

// reason: this builds a few lines of text at a time; `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use super::names::{camel, spoken};
use super::{Matched, Parser, Scope, Step};
use crate::diag::ParseResult;
use crate::ir;

impl Parser<'_> {
    /// Reads one `Process:` block into the process manager it describes.
    pub(super) fn process(&mut self, header: &Matched) -> ParseResult<ir::ProcessManager> {
        let mut pm = ir::ProcessManager {
            name: camel(&header.text_of("name")),
            ..Default::default()
        };
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Process", false)? {
            let Step::Phrase(m) = step else { continue };
            match m.id {
                "process_matched" => pm.correlates_by = m.text_of("path"),
                "process_starts" => pm.starts_on = Some(m.text_of("event")),
                "process_ends" => pm.ends_on = Some(m.text_of("event")),
                "process_when" | "process_when_refused" => {
                    let handler = self.handler(&m)?;
                    if let Some(earlier) = pm
                        .handlers
                        .iter()
                        .find(|h| h.event_type == handler.event_type && h.from_state == handler.from_state)
                    {
                        return Err(self.error(
                            m.line,
                            m.base_col,
                            format!(
                                "{} answers {} twice from {} (to {} and to {}); a step is chosen by the event and the state, so only one may answer",
                                spoken(&pm.name),
                                handler.event_type,
                                handler.from_state,
                                earlier.to_state,
                                handler.to_state
                            ),
                        ));
                    }
                    pm.handlers.push(handler);
                }
                _ => return Err(self.unmeant(&m)),
            }
        }
        if pm.correlates_by.is_empty() {
            return Err(self.error(
                header.line,
                header.base_col,
                "a process says what it is matched up by, like `It is matched up by reference.value`",
            ));
        }
        pm.states = crate::parse::process_manager::derived_states(&pm.handlers);
        Ok(pm)
    }

    /// One step: the event and states it answers, and the commands it tells aggregates to run.
    fn handler(&mut self, header: &Matched) -> ParseResult<ir::ProcessManagerHandler> {
        let mut handler = ir::ProcessManagerHandler {
            event_type: if header.id == "process_when" { header.text_of("event") } else { "refused".to_string() },
            from_state: header.text_of("from"),
            to_state: header.text_of("to"),
            dispatches: Vec::new(),
        };
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Handler", false)? {
            let Step::Phrase(m) = step else { continue };
            let spec = ir::DispatchSpec {
                command_name: format!("{}.{}", camel(&m.text_of("owner")), camel(&m.text_of("command"))),
                with_spec: if m.id.ends_with("with") { self.with_pairs(&m)? } else { Vec::new() },
                compensates: None,
            };
            match m.id {
                "process_tell" | "process_tell_with" => handler.dispatches.push(spec),
                "process_undo" | "process_undo_with" => {
                    let Some(last) = handler.dispatches.last_mut() else {
                        return Err(self.error(m.line, m.base_col, "`If that is refused` follows a `Then … is told to …` line"));
                    };
                    last.compensates = Some(Box::new(spec));
                }
                _ => return Err(self.unmeant(&m)),
            }
        }
        Ok(handler)
    }
}

/// A process manager as a `Process:` block, or the name of what in it the sentence form cannot say.
pub(super) fn said(pm: &ir::ProcessManager) -> Result<String, String> {
    let refused = |what: &str| format!("the sentence form has no phrase for {what} in process {}", pm.name);
    if pm.states != crate::parse::process_manager::derived_states(&pm.handlers) {
        return Err(refused("states that are not the ones its steps name"));
    }
    if !pm.correlates_by.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '/')) || pm.correlates_by.is_empty() {
        return Err(refused("this way of matching up"));
    }
    let mut out = format!("\nProcess: {}\n", super::format::spoken_title(&pm.name));
    out.push_str(&format!("  It is matched up by {}\n", pm.correlates_by));
    if let Some(event) = &pm.starts_on {
        out.push_str(&format!("  It starts when {event} is announced\n"));
    }
    if let Some(event) = &pm.ends_on {
        out.push_str(&format!("  It ends when {event} is announced\n"));
    }
    for handler in &pm.handlers {
        if !super::format::is_name(&handler.from_state) || !super::format::is_name(&handler.to_state) {
            return Err(refused("these state names"));
        }
        let when = if handler.event_type == "refused" {
            "it is refused".to_string()
        } else {
            format!("{} is announced", handler.event_type)
        };
        out.push_str(&format!(
            "\n  When {when} and it is {}, it moves to {}\n",
            handler.from_state, handler.to_state
        ));
        for dispatch in &handler.dispatches {
            out.push_str(&format!("    Then {}\n", dispatch_said(dispatch, &refused)?));
            if let Some(undo) = &dispatch.compensates {
                if undo.compensates.is_some() {
                    return Err(refused("an undo that is itself undone"));
                }
                out.push_str(&format!("    If that is refused, {}\n", dispatch_said(undo, &refused)?));
            }
        }
    }
    Ok(out)
}

/// `the account is told to debit with number from the source`.
fn dispatch_said(dispatch: &ir::DispatchSpec, refused: &dyn Fn(&str) -> String) -> Result<String, String> {
    let (owner, command) = dispatch
        .command_name
        .split_once('.')
        .ok_or_else(|| refused("a command with no aggregate"))?;
    let told = format!("the {} is told to {}", spoken(owner), spoken(command));
    if dispatch.with_spec.is_empty() {
        return Ok(told);
    }
    let items = super::changes::row_items(&dispatch.with_spec).ok_or_else(|| refused("this way of passing values"))?;
    Ok(format!("{told} with {items}"))
}
