//! Collecting refusals within a stage, for a dry run that answers every reason a command would be
//! refused. A real dispatch has no collector bound, so `refuse` raises the first refusal at once,
//! exactly as before.

use super::Refusal;
use std::cell::RefCell;

thread_local! {
    static COLLECTED: RefCell<Option<Vec<Refusal>>> = const { RefCell::new(None) };
}

/// Runs `body` with a collector bound and returns its result with every refusal `refuse` collected.
pub fn collecting<T>(body: impl FnOnce() -> T) -> (T, Vec<Refusal>) {
    COLLECTED.with(|slot| *slot.borrow_mut() = Some(Vec::new()));
    let result = body();
    let collected = COLLECTED.with(|slot| slot.borrow_mut().take().unwrap_or_default());
    (result, collected)
}

/// Raises `refusal`, or, when a collector is bound, keeps it and lets the stage go on to the next rule.
pub fn refuse(refusal: Refusal) -> Result<(), Refusal> {
    COLLECTED.with(|slot| match slot.borrow_mut().as_mut() {
        Some(collected) => {
            collected.push(refusal);
            Ok(())
        }
        None => Err(refusal),
    })
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
        first.map_or(Ok(()), |refusal| Err(refusal.clone()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn without_a_collector_a_refusal_is_raised_at_once() {
        assert_eq!(
            refuse(Refusal::GivenNotMet("a".into())),
            Err(Refusal::GivenNotMet("a".into()))
        );
        assert_eq!(settle(0), Ok(()));
    }

    #[test]
    fn with_a_collector_a_stage_keeps_every_refusal_then_fails_on_the_first() {
        let (stage, collected) = collecting(|| {
            let start = mark();
            refuse(Refusal::GivenNotMet("a".into()))?;
            refuse(Refusal::GivenNotMet("b".into()))?;
            settle(start)
        });

        assert_eq!(stage, Err(Refusal::GivenNotMet("a".into())));
        assert_eq!(
            collected,
            vec![
                Refusal::GivenNotMet("a".into()),
                Refusal::GivenNotMet("b".into())
            ]
        );
    }

    #[test]
    fn a_collector_is_unbound_once_collecting_returns() {
        collecting(|| ());

        assert_eq!(
            refuse(Refusal::Fault("x".into())),
            Err(Refusal::Fault("x".into()))
        );
    }
}
