//! The JSON body Resend's `POST /emails` takes for one message.

use crate::{Message, Sender};
use serde_json::{json, Value};

/// The request body: from, to, subject, an optional reply-to, the body as `html` when it opens
/// with a tag and as `text` otherwise, and `List-Unsubscribe` when the message has a leave link.
pub fn body(sender: &Sender, message: &Message) -> Vec<u8> {
    serde_json::to_vec(&value(sender, message)).unwrap_or_default()
}

fn value(sender: &Sender, message: &Message) -> Value {
    let mut payload =
        json!({ "from": sender.from, "to": [message.to], "subject": message.subject });
    if let Some(reply_to) = &sender.reply_to {
        payload["reply_to"] = json!(reply_to);
    }
    let content_key = if message.body.trim_start().starts_with('<') {
        "html"
    } else {
        "text"
    };
    payload[content_key] = json!(message.body);
    if let Some(url) = &message.unsubscribe_url {
        payload["headers"] = json!({ "List-Unsubscribe": format!("<{url}>") });
    }
    payload
}
