//! Collecting refusals within a stage, for a dry run that answers every reason a command would be
//! refused. A real dispatch has no collector bound, so `refuse` raises the first refusal at once,
//! exactly as before.

use super::Refusal;
use std::cell::RefCell;

/// What a refusal is about, beyond its text: the attribute and the JSON Pointer to the offending
/// value (an argument refusal), or the description of the rule that did not hold.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Detail {
    pub attribute: Option<String>,
    pub path: Option<String>,
    pub rule: Option<String>,
}

impl Detail {
    /// A refusal about the argument `name`, located at `/name`.
    pub fn attribute(name: &str) -> Self {
        Self {
            attribute: Some(name.to_string()),
            path: Some(format!("/{name}")),
            rule: None,
        }
    }

    /// A refusal because the rule described by `description` did not hold.
    pub fn rule(description: &str) -> Self {
        Self {
            rule: Some(description.to_string()),
            ..Self::default()
        }
    }
}

/// A refusal kept by a collector, with what it is about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collected {
    pub refusal: Refusal,
    pub detail: Detail,
}

thread_local! {
    static COLLECTED: RefCell<Option<Vec<Collected>>> = const { RefCell::new(None) };
}

/// Runs `body` with a collector bound and returns its result with everything `refuse` collected.
pub fn collecting<T>(body: impl FnOnce() -> T) -> (T, Vec<Collected>) {
    COLLECTED.with(|slot| *slot.borrow_mut() = Some(Vec::new()));
    let result = body();
    let collected = COLLECTED.with(|slot| slot.borrow_mut().take().unwrap_or_default());
    (result, collected)
}

/// Raises `refusal`, or, when a collector is bound, keeps it and lets the stage go on to the next rule.
pub fn refuse(refusal: Refusal) -> Result<(), Refusal> {
    refuse_with(refusal, Detail::default())
}

/// `refuse`, naming what the refusal is about.
pub fn refuse_with(refusal: Refusal, detail: Detail) -> Result<(), Refusal> {
    COLLECTED.with(|slot| match slot.borrow_mut().as_mut() {
        Some(collected) => {
            collected.push(Collected { refusal, detail });
            Ok(())
        }
        None => Err(refusal),
    })
}

/// Refuses every name in `names`. With a collector bound that is one refusal per name, each about
/// its own argument, and the stage is left to `settle`; with none, one refusal naming them all,
/// raised at once, as a real dispatch words it.
pub fn refuse_each(names: &[&str], make: impl Fn(&[&str]) -> Refusal) -> Result<(), Refusal> {
    let bound = COLLECTED.with(|slot| slot.borrow().is_some());
    if !bound {
        return Err(make(names));
    }
    for name in names {
        refuse_with(make(&[name]), Detail::attribute(name))?;
    }
    Ok(())
}

/// How many refusals the collector holds; the mark a stage settles against.
pub fn mark() -> usize {
    COLLECTED.with(|slot| slot.borrow().as_ref().map_or(0, Vec::len))
}

/// Ends a stage: raises the first refusal it collected since `mark`, so the stage still fails
/// after every one of its rules has been read.
pub fn settle(mark: usize) -> Result<(), Refusal> {
    COLLECTED.with(|slot| {
        let collected = slot.borrow();
        let first = collected.as_ref().and_then(|all| all.get(mark));
        first.map_or(Ok(()), |kept| Err(kept.refusal.clone()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn given(text: &str) -> Refusal {
        Refusal::GivenNotMet(text.into())
    }

    fn refusals(collected: &[Collected]) -> Vec<Refusal> {
        collected.iter().map(|kept| kept.refusal.clone()).collect()
    }

    #[test]
    fn without_a_collector_a_refusal_is_raised_at_once() {
        assert_eq!(refuse(given("a")), Err(given("a")));
        assert_eq!(settle(0), Ok(()));
    }

    #[test]
    fn with_a_collector_a_stage_keeps_every_refusal_then_fails_on_the_first() {
        let (stage, collected) = collecting(|| {
            let start = mark();
            refuse(given("a"))?;
            refuse(given("b"))?;
            settle(start)
        });

        assert_eq!(stage, Err(given("a")));
        assert_eq!(refusals(&collected), vec![given("a"), given("b")]);
    }

    #[test]
    fn a_collector_is_unbound_once_collecting_returns() {
        collecting(|| ());

        assert_eq!(
            refuse(Refusal::Fault("x".into())),
            Err(Refusal::Fault("x".into()))
        );
    }

    #[test]
    fn a_refusal_keeps_the_rule_or_attribute_it_was_about() {
        let ((), collected) = collecting(|| {
            let _ = refuse_with(given("a"), Detail::rule("the flow is positive"));
            let _ = refuse_with(given("b"), Detail::attribute("amount"));
        });

        assert_eq!(
            collected[0].detail.rule.as_deref(),
            Some("the flow is positive")
        );
        assert_eq!(collected[1].detail.path.as_deref(), Some("/amount"));
    }

    #[test]
    fn refusing_each_name_is_one_refusal_per_name_when_collecting_and_one_for_all_when_not() {
        let make = |names: &[&str]| Refusal::AbsentArgument(names.join(","));

        assert_eq!(
            refuse_each(&["a", "b"], make),
            Err(Refusal::AbsentArgument("a,b".into()))
        );
        let (outcome, collected) = collecting(|| refuse_each(&["a", "b"], make));
        assert_eq!(outcome, Ok(()));
        assert_eq!(
            refusals(&collected),
            vec![
                Refusal::AbsentArgument("a".into()),
                Refusal::AbsentArgument("b".into())
            ]
        );
        assert_eq!(collected[1].detail.attribute.as_deref(), Some("b"));
    }
}
