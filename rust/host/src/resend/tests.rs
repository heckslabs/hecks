#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use super::cases::{self, FakeResend, FROM, KEY};
use super::*;

fn native(base: &str, reply_to: Option<&str>) -> Mailer {
    Mailer::live(KEY, FROM, base).replying_to(reply_to.unwrap_or_default())
}

fn wasm(base: &str, reply_to: Option<&str>) -> Mailer {
    Mailer::component(KEY, FROM, base).replying_to(reply_to.unwrap_or_default())
}

#[tokio::test]
async fn the_native_mailer_passes_every_shared_case() {
    let failures = cases::run(native).await;
    assert!(failures.is_empty(), "{failures:#?}");
}

#[tokio::test]
async fn the_component_mailer_passes_every_shared_case() {
    let failures = cases::run(wasm).await;
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn the_embedded_component_is_the_build_its_digest_names() {
    assert_eq!(component::embedded_digest(), component::committed_digest());
}

#[test]
fn nothing_configured_is_not_a_mailer() {
    assert!(Mailer::configured("", "", "", "").unwrap().is_none());
}

#[test]
fn a_key_without_a_from_address_is_refused() {
    assert!(Mailer::configured("re_x", "", "", "1").is_err());
}

#[test]
fn a_key_and_from_is_live_even_when_mock_is_also_set() {
    let mailer = Mailer::configured("re_x", "News <n@mail.example.com>", "1", "")
        .unwrap()
        .unwrap();
    assert!(matches!(mailer, Mailer::Live { .. }));
}

#[test]
fn the_component_switch_picks_the_component_mailer() {
    let mailer = Mailer::configured("re_x", "n@mail.example.com", "", "1")
        .unwrap()
        .unwrap();
    assert!(matches!(mailer, Mailer::Component(_)));
}

#[test]
fn mock_needs_an_explicit_opt_in_and_no_key() {
    assert!(Mailer::configured("", "", "1", "")
        .unwrap()
        .unwrap()
        .is_mock());
    assert!(Mailer::configured("", "", "0", "1").unwrap().is_none());
}

#[test]
fn replying_to_trims_the_address_and_a_blank_one_sets_none() {
    let set =
        Mailer::live("re_x", "n@mail.example.com", "http://x").replying_to("  me@example.com ");
    assert!(
        matches!(&set, Mailer::Live { account, .. } if account.reply_to.as_deref() == Some("me@example.com"))
    );
    let blank = Mailer::component("re_x", "n@mail.example.com", "http://x").replying_to("   ");
    assert!(matches!(&blank, Mailer::Component(account) if account.reply_to.is_none()));
    assert!(
        Mailer::Mock.replying_to("me@example.com").is_mock(),
        "a mock mailer has no replies"
    );
}

#[test]
fn the_mock_logs_instead_of_sending_and_bounces_the_test_address() {
    let email = |to| Email {
        to,
        subject: "s",
        body: "x",
        unsubscribe_url: None,
    };
    let sent = mock_deliver(&email("a@b.com"));
    assert!(sent.ok && sent.message_id.unwrap().starts_with("re_"));
    assert_eq!(
        mock_deliver(&email(MOCK_BOUNCE_ADDRESS)),
        Delivery::failed("bounced")
    );
}

#[tokio::test]
async fn the_component_reaches_no_host_but_the_base_urls() {
    let fake = FakeResend::start(vec![("200 OK", "", r#"{"id":"em_1"}"#)]);
    let account = Account::new(KEY, FROM, "http://localhost:1");
    let mut sender_on_another_host = component::sender(&account);
    sender_on_another_host.base_url = fake.base.clone();
    let delivery = component::deliver_as(&account, sender_on_another_host, &probe()).await;
    assert_eq!(
        delivery.reason.as_deref(),
        Some("resend unreachable: 127.0.0.1 is not granted")
    );
}

/// Per-delivery cost, native against component, on the local fake, sequential and concurrent.
/// Run by hand: `cargo test --release resend::tests::overhead -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "a measurement, not a check"]
async fn overhead() {
    const N: usize = 50;
    for (label, build) in [("native", native as cases::Build), ("component", wasm)] {
        // One warm-up delivery compiles the component, so the timing is per call.
        let warm = FakeResend::start(vec![("200 OK", "", r#"{"id":"em"}"#)]);
        build(&warm.base, None).deliver(&probe()).await;
        let answers = vec![("200 OK", "", r#"{"id":"em"}"#); N];
        let fake = FakeResend::start(answers);
        let mailer = build(&fake.base, None);
        let started = std::time::Instant::now();
        for _ in 0..N {
            assert!(mailer.deliver(&probe()).await.ok);
        }
        let each = started.elapsed().as_secs_f64() * 1000.0 / N as f64;
        println!("{label}: {each:.2} ms per delivery, sequential ({N})");
        concurrent(label, build).await;
    }
}

async fn concurrent(label: &str, build: cases::Build) {
    const N: usize = 16;
    let fake = FakeResend::start(vec![("200 OK", "", r#"{"id":"em"}"#); N]);
    let mailer = std::sync::Arc::new(build(&fake.base, None));
    let started = std::time::Instant::now();
    let runs: Vec<_> = (0..N)
        .map(|_| {
            let mailer = mailer.clone();
            tokio::spawn(async move { mailer.deliver(&probe()).await.ok })
        })
        .collect();
    for run in runs {
        assert!(run.await.unwrap());
    }
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    println!("{label}: {N} concurrent deliveries in {ms:.2} ms");
}

fn probe() -> Email<'static> {
    Email {
        to: "a@b.com",
        subject: "s",
        body: "<p>x</p>",
        unsubscribe_url: None,
    }
}
