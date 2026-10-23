use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long an address is left alone after a confirmation email went to it.
pub(super) const WINDOW: Duration = Duration::from_mins(10);

/// The most addresses remembered; past it the oldest is forgotten to make room.
pub(super) const CAPACITY: usize = 10_000;

/// The most confirmation emails sent to anyone in one window, so a flood of distinct addresses
/// cannot turn the form into a mailer.
pub(super) const GLOBAL_LIMIT: usize = 500;

/// A per-address cooldown on confirmation emails, so the form cannot mail-bomb someone, under a
/// cap on how many go out in all.
///
/// An address is keyed by the mailbox it reaches (`mailbox_key`), so spelling variants that land in
/// one inbox share one cooldown.
///
/// In-process: not shared between tasks and lost on restart, so each task has its own window.
pub(super) struct ConfirmationCooldown {
    window: Duration,
    capacity: usize,
    global_limit: usize,
    state: Mutex<Sent>,
}

#[derive(Default)]
struct Sent {
    by_mailbox: HashMap<String, Instant>,
    all: VecDeque<Instant>,
}

impl ConfirmationCooldown {
    pub(super) fn new(window: Duration, capacity: usize, global_limit: usize) -> Self {
        Self {
            window,
            capacity,
            global_limit,
            state: Mutex::new(Sent::default()),
        }
    }

    /// Whether an email may go to `email` now. A `true` records the send, so the caller must then
    /// send.
    pub(super) fn try_acquire(&self, email: &str) -> bool {
        self.try_acquire_at(email, Instant::now())
    }

    /// `try_acquire` with the clock supplied, so tests need not sleep.
    pub(super) fn try_acquire_at(&self, email: &str, now: Instant) -> bool {
        let key = mailbox_key(email);
        let mut sent = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let window = self.window;
        let live = |at: &Instant| now.saturating_duration_since(*at) < window;
        sent.by_mailbox.retain(|_, at| live(at));
        while sent.all.front().is_some_and(|at| !live(at)) {
            sent.all.pop_front();
        }
        if sent.by_mailbox.contains_key(&key) || sent.all.len() >= self.global_limit {
            return false;
        }
        if sent.by_mailbox.len() >= self.capacity {
            forget_oldest(&mut sent.by_mailbox);
        }
        sent.by_mailbox.insert(key, now);
        sent.all.push_back(now);
        true
    }

    #[cfg(test)]
    fn remembered(&self) -> usize {
        self.state.lock().unwrap().by_mailbox.len()
    }
}

fn forget_oldest(by_mailbox: &mut HashMap<String, Instant>) {
    let oldest = by_mailbox
        .iter()
        .min_by_key(|(_, at)| **at)
        .map(|(key, _)| key.clone());
    if let Some(oldest) = oldest {
        by_mailbox.remove(&oldest);
    }
}

/// The mailbox `email` reaches: lowercased, without a `+tag`, and for Gmail without the dots it
/// ignores and with `googlemail.com` read as `gmail.com`.
pub(super) fn mailbox_key(email: &str) -> String {
    let email = email.trim().to_lowercase();
    let Some((local, domain)) = email.rsplit_once('@') else {
        return email;
    };
    let local = local.split('+').next().unwrap_or(local);
    match domain {
        "gmail.com" | "googlemail.com" => format!("{}@gmail.com", local.replace('.', "")),
        _ => format!("{local}@{domain}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cooldown() -> ConfirmationCooldown {
        ConfirmationCooldown::new(Duration::from_secs(600), 3, 100)
    }

    #[test]
    fn the_first_send_is_allowed_and_a_second_inside_the_window_is_not() {
        let (cooldown, start) = (cooldown(), Instant::now());
        assert!(cooldown.try_acquire_at("a@example.com", start));
        assert!(!cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(1)));
        assert!(!cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(599)));
    }

    #[test]
    fn the_address_is_allowed_again_once_the_window_has_passed() {
        let (cooldown, start) = (cooldown(), Instant::now());
        assert!(cooldown.try_acquire_at("a@example.com", start));
        assert!(cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(600)));
        assert!(!cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(601)));
    }

    #[test]
    fn a_refused_attempt_does_not_extend_the_window() {
        let (cooldown, start) = (cooldown(), Instant::now());
        assert!(cooldown.try_acquire_at("a@example.com", start));
        assert!(!cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(500)));
        assert!(cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(600)));
    }

    #[test]
    fn the_key_is_the_mailbox_the_address_reaches() {
        let (cooldown, start) = (cooldown(), Instant::now());
        assert!(cooldown.try_acquire_at("Ann@Example.com", start));
        assert!(!cooldown.try_acquire_at("ann@example.COM", start));
    }

    #[test]
    fn different_addresses_do_not_limit_each_other() {
        let (cooldown, start) = (cooldown(), Instant::now());
        assert!(cooldown.try_acquire_at("a@example.com", start));
        assert!(cooldown.try_acquire_at("b@example.com", start));
    }

    #[test]
    fn expired_entries_are_pruned() {
        let (cooldown, start) = (cooldown(), Instant::now());
        cooldown.try_acquire_at("a@example.com", start);
        cooldown.try_acquire_at("b@example.com", start);
        assert_eq!(cooldown.remembered(), 2);
        assert!(cooldown.try_acquire_at("c@example.com", start + Duration::from_secs(700)));
        assert_eq!(cooldown.remembered(), 1);
    }

    #[test]
    fn at_capacity_a_new_address_forgets_the_oldest_rather_than_being_refused() {
        let (cooldown, start) = (cooldown(), Instant::now());
        for (i, address) in ["a@example.com", "b@example.com", "c@example.com"]
            .iter()
            .enumerate()
        {
            assert!(cooldown.try_acquire_at(address, start + Duration::from_secs(i as u64)));
        }
        assert!(cooldown.try_acquire_at("d@example.com", start + Duration::from_secs(5)));
        assert_eq!(cooldown.remembered(), 3);
        assert!(cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(6)));
        assert!(!cooldown.try_acquire_at("d@example.com", start + Duration::from_secs(7)));
    }

    #[test]
    fn at_capacity_expired_entries_make_room_first() {
        let (cooldown, start) = (cooldown(), Instant::now());
        for address in ["a@example.com", "b@example.com", "c@example.com"] {
            assert!(cooldown.try_acquire_at(address, start));
        }
        assert!(cooldown.try_acquire_at("d@example.com", start + Duration::from_secs(600)));
        assert_eq!(cooldown.remembered(), 1);
    }

    #[test]
    fn spelling_variants_of_one_gmail_inbox_share_one_cooldown() {
        let (cooldown, start) = (cooldown(), Instant::now());
        assert!(cooldown.try_acquire_at("victim@gmail.com", start));
        for variant in [
            "v.i.c.t.i.m@gmail.com",
            "victim+1@gmail.com",
            "Vic.Tim+x@GoogleMail.com",
        ] {
            assert!(!cooldown.try_acquire_at(variant, start), "{variant}");
        }
    }

    #[test]
    fn a_plus_tag_is_the_same_mailbox_anywhere_but_dots_only_fold_at_gmail() {
        assert_eq!(mailbox_key(" Ann+news@Example.com "), "ann@example.com");
        assert_eq!(mailbox_key("a.nn@example.com"), "a.nn@example.com");
        assert_eq!(mailbox_key("a.nn+x@googlemail.com"), "ann@gmail.com");
        assert_eq!(mailbox_key("no-at-sign"), "no-at-sign");
    }

    #[test]
    fn past_the_global_limit_no_address_is_mailed_until_the_window_moves_on() {
        let (cooldown, start) = (
            ConfirmationCooldown::new(Duration::from_secs(600), 100, 2),
            Instant::now(),
        );
        assert!(cooldown.try_acquire_at("a@example.com", start));
        assert!(cooldown.try_acquire_at("b@example.com", start + Duration::from_secs(1)));
        assert!(!cooldown.try_acquire_at("c@example.com", start + Duration::from_secs(2)));
        assert!(cooldown.try_acquire_at("c@example.com", start + Duration::from_secs(600)));
    }
}
