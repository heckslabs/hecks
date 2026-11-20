//! Makes a business's own Stripe calls from inside a Wasm component: reading the account,
//! creating and deleting the webhook endpoint, and opening an embedded checkout session. It holds
//! the request shapes and the mapping of Stripe's answers; the host lends it the request
//! (`http-out`) and hands each call the key it chose, so the component reads no secret itself.

// The generated export glue takes every record field as an argument.
#![allow(clippy::too_many_arguments)]

wit_bindgen::generate!({
    path: "../../host/wit",
    world: "payments-adapter",
});

mod answer;
mod form;
mod request;

use hecks::adapters::http_out;

struct Stripe;

impl Guest for Stripe {
    fn read_account(account: Account) -> Result<Option<String>, AccountRefusal> {
        let reply = http_out::request(&request::get(&account, "/v1/account"))
            .map_err(|_| AccountRefusal::Unreachable)?;
        match reply.status {
            401 => Err(AccountRefusal::KeyRefused),
            200..=299 => Ok(answer::business_name(&answer::json(&reply.body))),
            _ => Err(AccountRefusal::Declined),
        }
    }

    fn create_webhook(account: Account, wanted: WebhookRequest) -> Result<Endpoint, WebhookRefusal> {
        let call = request::post(&account, "/v1/webhook_endpoints", &form::webhook(&wanted));
        let reply = http_out::request(&call).map_err(|_| WebhookRefusal::Other)?;
        answer::endpoint(&reply)
    }

    fn delete_webhook(account: Account, endpoint_id: String) -> bool {
        let path = format!("/v1/webhook_endpoints/{endpoint_id}");
        http_out::request(&request::delete(&account, &path))
            .is_ok_and(|reply| (200..300).contains(&reply.status))
    }

    fn create_checkout_session(
        account: Account,
        wanted: SessionRequest,
    ) -> Result<EmbeddedSession, String> {
        let call = request::post(&account, "/v1/checkout/sessions", &form::session(&wanted));
        let reply = http_out::request(&call).map_err(answer::unreachable)?;
        answer::session(&reply)
    }
}

export!(Stripe);
