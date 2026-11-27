//! Reads a supervisor's tells and measures the mail against the baseline the work started from.
//!
//! Two times are measured, in milliseconds:
//!
//! - **delivery**: from a `sent` tell to the `delivered` tell of the same message, the time a
//!   message waits before its addressee starts on it;
//! - **block to answer**: from a question's `sent` to the delivery of the first message its
//!   addressee sends back, the time the asker waits for its answer.
//!
//! The baseline is the mail as it was measured before the harness: answer delivery p90 322 s and
//! block to answer p90 673 s.

use std::collections::BTreeMap;

use crate::json::{self, Value};

/// The baseline's answer delivery, p90, in milliseconds.
pub const BASELINE_DELIVERY_P90_MS: f64 = 322_000.0;

/// The baseline's block to answer, p90, in milliseconds.
pub const BASELINE_ANSWER_P90_MS: f64 = 673_000.0;

/// One message as the tells show it.
#[derive(Debug, Clone, PartialEq)]
struct Mail {
    from: String,
    to: String,
    sent_ms: f64,
    delivered_ms: Option<f64>,
}

/// A spread of times: how many, and the p50, p90 and largest.
#[derive(Debug, Clone, PartialEq)]
pub struct Spread {
    pub count: usize,
    pub p50: f64,
    pub p90: f64,
    pub max: f64,
}

impl Spread {
    fn of(mut times: Vec<f64>) -> Self {
        times.sort_by(f64::total_cmp);
        Self {
            count: times.len(),
            p50: rank(&times, 0.5),
            p90: rank(&times, 0.9),
            max: times.last().copied().unwrap_or(0.0),
        }
    }

    fn to_value(&self) -> Value {
        Value::object(vec![
            ("count", Value::Number(self.count as f64)),
            ("p50_ms", Value::Number(self.p50)),
            ("p90_ms", Value::Number(self.p90)),
            ("max_ms", Value::Number(self.max)),
        ])
    }
}

/// What the tells measure.
#[derive(Debug, Clone, PartialEq)]
pub struct Measured {
    pub messages: usize,
    pub undelivered: usize,
    pub delivery: Spread,
    pub answer: Spread,
}

impl Measured {
    /// Whether each p90 is at or under its baseline, and every message was delivered.
    pub fn within_baseline(&self) -> bool {
        self.undelivered == 0
            && self.delivery.count > 0
            && self.delivery.p90 <= BASELINE_DELIVERY_P90_MS
            && self.answer.p90 <= BASELINE_ANSWER_P90_MS
    }

    /// The measure as one JSON object, beside the baseline.
    pub fn to_value(&self) -> Value {
        Value::object(vec![
            ("messages", Value::Number(self.messages as f64)),
            ("undelivered", Value::Number(self.undelivered as f64)),
            ("delivery", self.delivery.to_value()),
            ("block_to_answer", self.answer.to_value()),
            (
                "baseline",
                Value::object(vec![
                    ("delivery_p90_ms", Value::Number(BASELINE_DELIVERY_P90_MS)),
                    (
                        "block_to_answer_p90_ms",
                        Value::Number(BASELINE_ANSWER_P90_MS),
                    ),
                ]),
            ),
            ("within_baseline", Value::Bool(self.within_baseline())),
        ])
    }
}

/// Measures the tells, one JSON object a line; lines that are not tells are skipped.
pub fn measure(tells: &str) -> Measured {
    let mut mail: BTreeMap<String, Mail> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    for line in tells.lines() {
        let Ok(tell) = json::parse(line) else {
            continue;
        };
        let at = tell.get("at_ms").and_then(Value::as_f64).unwrap_or(0.0);
        let message = tell.str_at("message").unwrap_or_default().to_string();
        match tell.str_at("tell") {
            Some("sent") => {
                let from = tell.str_at("session").unwrap_or_default().to_string();
                let to = tell.str_at("to").unwrap_or_default().to_string();
                order.push(message.clone());
                mail.insert(
                    message,
                    Mail {
                        from,
                        to,
                        sent_ms: at,
                        delivered_ms: None,
                    },
                );
            }
            Some("delivered") => {
                if let Some(sent) = mail.get_mut(&message) {
                    sent.delivered_ms.get_or_insert(at);
                }
            }
            _ => {}
        }
    }
    let delivery: Vec<f64> = mail
        .values()
        .filter_map(|sent| sent.delivered_ms.map(|delivered| delivered - sent.sent_ms))
        .collect();
    let answer: Vec<f64> = order
        .iter()
        .enumerate()
        .filter_map(|(index, id)| {
            let question = &mail[id];
            order[index + 1..]
                .iter()
                .map(|later| &mail[later])
                .find(|reply| reply.from == question.to && reply.to == question.from)
                .and_then(|reply| reply.delivered_ms)
                .map(|answered| answered - question.sent_ms)
        })
        .collect();
    Measured {
        messages: mail.len(),
        undelivered: mail
            .values()
            .filter(|sent| sent.delivered_ms.is_none())
            .count(),
        delivery: Spread::of(delivery),
        answer: Spread::of(answer),
    }
}

/// The nearest-rank percentile of sorted times; 0 when there are none.
fn rank(sorted: &[f64], share: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let at = (share * sorted.len() as f64).ceil() as usize;
    sorted[at.clamp(1, sorted.len()) - 1]
}

#[cfg(test)]
mod tests {
    use super::*;

    const TELLS: &str = r#"{"tell":"ready","at_ms":0}
{"tell":"sent","at_ms":100,"session":"reviewer","message":"reviewer-1","to":"coder","text":"q"}
{"tell":"queued","at_ms":101,"session":"coder","message":"reviewer-1","held":1}
{"tell":"delivered","at_ms":150,"session":"coder","message":"reviewer-1","from":"reviewer"}
{"tell":"sent","at_ms":400,"session":"coder","message":"coder-1","to":"reviewer","text":"a"}
{"tell":"delivered","at_ms":402,"session":"reviewer","message":"coder-1","from":"coder"}
"#;

    #[test]
    fn measures_delivery_from_sent_to_delivered() {
        let measured = measure(TELLS);
        assert_eq!(
            measured.delivery,
            Spread {
                count: 2,
                p50: 2.0,
                p90: 50.0,
                max: 50.0
            }
        );
    }

    #[test]
    fn measures_block_to_answer_from_the_question_to_the_answer_delivered() {
        assert_eq!(
            measure(TELLS).answer,
            Spread {
                count: 1,
                p50: 302.0,
                p90: 302.0,
                max: 302.0
            }
        );
    }

    #[test]
    fn is_within_the_baseline_when_everything_arrives_fast() {
        assert!(measure(TELLS).within_baseline());
    }

    #[test]
    fn an_undelivered_message_is_not_within_the_baseline() {
        let tells = format!(
            "{TELLS}{}",
            r#"{"tell":"sent","at_ms":500,"session":"coder","message":"coder-2","to":"x","text":"b"}"#
        );
        let measured = measure(&tells);
        assert_eq!(
            (measured.undelivered, measured.within_baseline()),
            (1, false)
        );
    }

    #[test]
    fn takes_the_nearest_rank() {
        let times: Vec<f64> = (1..=10).map(f64::from).collect();
        assert_eq!((rank(&times, 0.5), rank(&times, 0.9)), (5.0, 9.0));
    }
}
