use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long an address is left alone after a confirmation email went to it.
pub(super) const WINDOW: Duration = Duration::from_secs(10 * 60);

/// The most addresses remembered at once. Past it a new address is refused
/// (no email) rather than evicting one still inside its window.
pub(super) const CAPACITY: usize = 10_000;

/// A per-address cooldown on confirmation emails, so that submitting someone
/// else's address over and over cannot turn the form into a mail bomb.
///
/// The memory is in-process: it is not shared between processes and does not
/// survive a restart. The service runs one task today, so that is one window
/// per address; a second task would give each address one email per window per
/// task.
pub(super) struct ConfirmationCooldown {
    window: Duration,
    capacity: usize,
    last_sent: Mutex<HashMap<String, Instant>>,
}

impl ConfirmationCooldown {
    pub(super) fn new(window: Duration, capacity: usize) -> Self {
        Self { window, capacity, last_sent: Mutex::new(HashMap::new()) }
    }

    /// Whether an email may go to `email` now; when it may, the send is
    /// recorded, so the caller must then actually send. The key is the
    /// lowercased address.
    pub(super) fn try_acquire(&self, email: &str) -> bool {
        self.try_acquire_at(email, Instant::now())
    }

    /// `try_acquire` with the clock supplied, so tests need not sleep.
    pub(super) fn try_acquire_at(&self, email: &str, now: Instant) -> bool {
        let key = email.to_lowercase();
        let mut last_sent = self.last_sent.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let window = self.window;
        last_sent.retain(|_, sent| now.saturating_duration_since(*sent) < window);
        if last_sent.contains_key(&key) || last_sent.len() >= self.capacity {
            return false;
        }
        last_sent.insert(key, now);
        true
    }

    #[cfg(test)]
    fn remembered(&self) -> usize {
        self.last_sent.lock().unwrap().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cooldown() -> ConfirmationCooldown {
        ConfirmationCooldown::new(Duration::from_secs(600), 3)
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
    fn the_key_is_the_lowercased_address() {
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
    fn at_capacity_a_new_address_is_refused_and_no_live_entry_is_evicted() {
        let (cooldown, start) = (cooldown(), Instant::now());
        for address in ["a@example.com", "b@example.com", "c@example.com"] {
            assert!(cooldown.try_acquire_at(address, start));
        }
        assert!(!cooldown.try_acquire_at("d@example.com", start + Duration::from_secs(1)));
        assert_eq!(cooldown.remembered(), 3);
        assert!(!cooldown.try_acquire_at("a@example.com", start + Duration::from_secs(1)));
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
}
