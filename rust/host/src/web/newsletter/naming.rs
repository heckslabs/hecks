use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// How long after subscribing the signup form's second step may still name the subscriber.
pub(super) const WINDOW: Duration = Duration::from_mins(30);

/// The most fresh subscriptions remembered; past it the oldest is forgotten to make room.
pub(super) const CAPACITY: usize = 10_000;

/// The subscriptions this process recorded in the last `WINDOW`, which alone may be named without
/// the confirm token: anyone can type an address, so naming one that was already on the list would
/// let a stranger rename its subscriber.
///
/// In-process: a second step that reaches another task, or arrives after a restart, needs the token.
pub(super) struct NamingWindow {
    window: Duration,
    capacity: usize,
    subscribed: Mutex<HashMap<String, Instant>>,
}

impl NamingWindow {
    pub(super) fn new(window: Duration, capacity: usize) -> Self {
        Self {
            window,
            capacity,
            subscribed: Mutex::new(HashMap::new()),
        }
    }

    /// Records that `email` subscribed just now.
    pub(super) fn opened(&self, email: &str) {
        self.opened_at(email, Instant::now());
    }

    /// Whether `email` subscribed within the window.
    pub(super) fn is_open(&self, email: &str) -> bool {
        self.is_open_at(email, Instant::now())
    }

    fn opened_at(&self, email: &str, now: Instant) {
        let mut subscribed = self.lock();
        let window = self.window;
        subscribed.retain(|_, at| now.saturating_duration_since(*at) < window);
        if subscribed.len() >= self.capacity {
            let oldest = subscribed
                .iter()
                .min_by_key(|(_, at)| **at)
                .map(|(key, _)| key.clone());
            if let Some(oldest) = oldest {
                subscribed.remove(&oldest);
            }
        }
        subscribed.insert(email.to_string(), now);
    }

    fn is_open_at(&self, email: &str, now: Instant) -> bool {
        self.lock()
            .get(email)
            .is_some_and(|at| now.saturating_duration_since(*at) < self.window)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Instant>> {
        self.subscribed
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn naming() -> NamingWindow {
        NamingWindow::new(Duration::from_mins(30), 2)
    }

    #[test]
    fn an_address_may_be_named_only_inside_the_window_after_it_subscribed() {
        let (naming, start) = (naming(), Instant::now());
        assert!(!naming.is_open_at("a@example.com", start));
        naming.opened_at("a@example.com", start);
        assert!(naming.is_open_at("a@example.com", start + Duration::from_secs(1799)));
        assert!(!naming.is_open_at("a@example.com", start + Duration::from_mins(30)));
    }

    #[test]
    fn the_window_is_for_the_exact_address_that_subscribed() {
        let (naming, start) = (naming(), Instant::now());
        naming.opened_at("a@example.com", start);
        assert!(!naming.is_open_at("A@example.com", start));
        assert!(!naming.is_open_at("b@example.com", start));
    }

    #[test]
    fn at_capacity_the_oldest_subscription_is_forgotten() {
        let (naming, start) = (naming(), Instant::now());
        naming.opened_at("a@example.com", start);
        naming.opened_at("b@example.com", start + Duration::from_secs(1));
        naming.opened_at("c@example.com", start + Duration::from_secs(2));
        assert!(!naming.is_open_at("a@example.com", start + Duration::from_secs(3)));
        assert!(naming.is_open_at("c@example.com", start + Duration::from_secs(3)));
    }
}
