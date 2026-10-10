# The Rust host: environment and routes

`rust/host` is the binary that serves a compiled domain: it boots against
Postgres, mints or matches an era, and answers requests either as an AWS Lambda
custom runtime or, with `HECKS_SERVE_MODE=1`, as a plain HTTP server for a
`deployed_to("AwsFargate")` stack. This page lists the environment variables a
deploy sets for the parts of the host that are not the domain itself (checkout,
payments and the public-route rate limits) and the read routes a site can rely
on. The code is the authority: each section names the file it comes from.

The deploy projections write the stack's own variables (`HECKS_DOMAIN`,
`HECKS_WASM_PATH`, `HECKS_IR_PATH`, the database and secret variables). Nothing
on this page is written by them, so a deploy sets these itself, in the task
definition or the function's environment. See the
[wiring guide](guides/wiring.md#hosting-scripts-for-awsfargate) for
what the generated files do.

## Checkout, payments and the public routes

`HECKS_CHECKOUT_DOMAIN` switches the guest-facing routes on: the newsletter
subscribe form, event registration and checkout, the payment webhook, the seat
reads below, and the `/payments/connection` API. It must equal `HECKS_DOMAIN`
exactly. Set to anything else, or unset, none of those routes exist and the host
answers them as unknown paths. The registration, checkout and seat routes are
also served only when the domain's IR declares `provides "payments"`. The payment
states that still hold a seat come from the `holds_seat` list of that `payments` fact,
declared as `holds_seat: "Payment.holds_seat"` over a lifecycle `mark :holds_seat`; a
chapter that omits it gets the host's built-in default list and one warning.
The newsletter routes work the same way: the `newsletter` fact's
`awaiting_confirmation`, `receives_issues` and `left` lists (lifecycle marks the
chapter names in `provides "newsletter"`) say which subscriber states await the
confirm link, receive issues and count as left; a mark the chapter omits falls
back to `pending`, `confirmed` or `unsubscribed` with one warning.
The windows work the same way (ADR 0098): the `newsletter` fact's `confirm_window` and
`unsubscribe_window` (seconds, from `provides "newsletter"`) set how long the emailed confirm
and unsubscribe links live, and the `checkout` fact's `webhook_tolerance` and `session_hold`
(from `provides "checkout"`) set how fresh a signed payment webhook must be and how long a
session holds its seat. A window the chapter omits falls back to 14 days, 730 days, 5 minutes
or 30 minutes with one warning. The payment processor's own 31-minute minimum session expiry is
applied by the host on top of the domain's hold.

The failure reason a lapsed hold records and the registration timestamp work the same way
(ADR 0099): the `payments` fact's `lapse_reason` (from `provides "payments", lapse_reason:
"Payment.lapse_reason"`) is the reason the host sends when the processor reports a session
expired, and the `registrations` fact's `registered_at` names the attribute the admin list sorts
by. Omitted, they fall back to `checkout_expired` and the first of `created_at`, `registered_at`,
`requested_at`, `occurred_at` with one warning. The processor's event names, its name and its two
key modes are the Stripe adapter's own vocabulary and stay in the host.

| variable | default | meaning |
| --- | --- | --- |
| `HECKS_CHECKOUT_DOMAIN` | unset (routes off) | the domain whose guest routes are on; must equal `HECKS_DOMAIN` |
| `SITE_URL` | `http://localhost:4321` | the site's public origin |
| `NEWSLETTER_CONFIRMATION_TEMPLATE_URL` | unset (plain text) | URL of an HTML template for the signup confirmation email; `{{CONFIRM_URL}}` is required, `{{UNSUBSCRIBE_URL}}` optional. Fetched per send (5 s timeout, 256 KiB cap); any failure falls back to the plain-text email |
| `PAYMENTS_WEBHOOK_BASE_URL` | `SITE_URL` | the public origin Stripe delivers webhooks to; the webhook the host creates points at `<this>/webhooks/stripe` |
| `PAYMENTS_WEBHOOK_DESCRIPTION` | `<HECKS_DOMAIN> website` | the description Stripe shows beside the webhook endpoint the host creates in the business's account; blank means the default |
| `PAYMENTS_ACCOUNT_SECRET_ID` | none | the name of the Secrets Manager secret that holds the business's saved payment keys; required on AWS when checkout is enabled (below) |
| `PAYMENTS_OPERATOR_EMAILS` | none | comma-separated emails allowed to turn real payments on and off; never a tenant role |
| `STRIPE_ACCOUNT_TEST_KEY`, `STRIPE_ACCOUNT_TEST_PUBLISHABLE_KEY`, `STRIPE_ACCOUNT_LIVE_KEY`, `STRIPE_ACCOUNT_LIVE_PUBLISHABLE_KEY` | none | the business's own Stripe keys, one pair per mode; where set they win over keys saved from the Payments page |
| `STRIPE_WEBHOOK_SECRET` | none | the signing secret of the business's own webhook endpoint; while unset, the mock walkthrough's fixed secret is the one that verifies |
| `HECKS_SESSION_COOKIE` | `hecks_session` | the name of the account cookie; a name that is not letters, digits, `_`, `-` and `.` refuses the boot |

### The payment key store

Keys pasted into the Payments page are checked with Stripe and saved in one
Secrets Manager secret, never in the domain's database or its journal, and are
never logged or echoed. The secret's `SecretString` is a JSON document with a
`test` and a `live` entry, each holding `secret_key`, `publishable_key`,
`webhook_secret`, `webhook_endpoint_id` and `saved_at`. Reads go through a
one-minute cache that a save or a disconnect clears at once.

`PAYMENTS_ACCOUNT_SECRET_ID` names that secret. There is no default name. On AWS
(the host is on AWS when it runs as an ECS task or a Lambda function) with
checkout enabled, an unset or blank value refuses the boot before the database
is touched, with a message naming the variable. Off AWS, or with checkout off,
an unset value means there is no store: nothing can be saved from the Payments
page and only the `STRIPE_ACCOUNT_*` keys are used.

The task role (or the function's role) needs four Secrets Manager actions on
that one secret:

- `secretsmanager:GetSecretValue`
- `secretsmanager:PutSecretValue`
- `secretsmanager:CreateSecret`
- `secretsmanager:DescribeSecret`

Secrets Manager gives every secret an ARN ending in a random six-character
suffix, so a policy that names the secret by its name ends in `-*`.

## Rate limits on the public write routes

Two routes a stranger can call are limited per client address, in front of
dispatch, so a refused request costs no Postgres lock, wasm run or journal write:
`POST /newsletter/subscribers` and `POST /registrations`. Reads, the
token-authenticated confirm and unsubscribe links, the payment webhook and every
authenticated route are never limited. The limits exist in serve mode
(`HECKS_SERVE_MODE=1`); a limited caller gets `429 Too Many Requests` with a
`Retry-After` header (whole seconds until the oldest counted request leaves the
window) and the host's usual JSON error body,
`{"error": "too many requests, please try again later"}`.

Each address keeps the timestamps of its recent allowed requests, and a request
is refused once `limit` of them fall inside the last window. Refused requests are
not recorded, so hammering a route never extends the caller's own lockout. IPv6
callers are counted per /64. The state lives in the process only: with more than
one host task behind the load balancer the effective limit is per task, and a
restart clears it. This is abuse damping, not a hard quota.

| variable | default | meaning |
| --- | --- | --- |
| `HECKS_RATE_LIMIT` | on | `off`, `false`, `0`, `no` or `disabled` turns every limit off |
| `HECKS_RATE_LIMIT_WINDOW_SECONDS` | 3600 | window length for every limited route |
| `HECKS_RATE_LIMIT_SUBSCRIBE` | 10 | requests per address per window, subscribe |
| `HECKS_RATE_LIMIT_REGISTER` | 15 | requests per address per window, registration |
| `HECKS_RATE_LIMIT_MAX_KEYS` | 10000 | most addresses tracked at once |
| `HECKS_TRUSTED_PROXIES` | none | comma-separated addresses or `addr/prefix` ranges |
| `HECKS_TRUSTED_PROXY_HOPS` | 0 | rightmost `X-Forwarded-For` entries added by our proxies |
| `HECKS_PROXY_AUTH_HEADER` | none | header a trusted proxy sets to prove it forwarded the request |
| `HECKS_PROXY_AUTH_SECRET` | none | the value that header must carry; both must be set |

A number that is blank, zero or not a whole number falls back to its default,
and a bad list entry is dropped. The defaults admit a smoke run several times
over from one address.

### Which address is the client

The TCP peer is the client unless a proxy in front of the host says otherwise.
`X-Forwarded-For` is trusted only when the request provably came through your own
proxy, because otherwise the caller typed it:

- the peer address is inside `HECKS_TRUSTED_PROXIES`, or
- the request carries the header named by `HECKS_PROXY_AUTH_HEADER` with the
  value `HECKS_PROXY_AUTH_SECRET`, a secret the CDN or load balancer adds to
  every origin request.

A trusted request is resolved by walking `X-Forwarded-For` from the right: the
rightmost `HECKS_TRUSTED_PROXY_HOPS` entries belong to proxies that cannot be
listed by address, then every entry inside `HECKS_TRUSTED_PROXIES` is skipped,
and the first remaining entry is the client. The leftmost entries are whatever
the caller typed and are never reached. A header shorter than the walk implies,
or a client entry that is not an address, yields no client, and those requests
share one bucket rather than trust a guess.

Behind a CDN and then a load balancer the header reads
`<typed by caller>, <client>, <CDN edge>`, so authenticate with the shared secret
and set the hops to 1. A sidecar or a single proxy on a fixed address needs only
the list.

### The deploy risk

Behind a proxy or a load balancer, the TCP peer the host sees is the proxy, not
the visitor. Unless the trust variables are set, every visitor is counted as that
one address and shares one bucket: ten subscribe requests an hour for the whole
site, after which every real visitor is refused. Set `HECKS_TRUSTED_PROXIES` (or
the proxy-authentication pair, plus the hops) on any stack that has a proxy in
front of the host, and check it after the first deploy.

Two things break the resolution even when it is configured: a hop added or
removed in front of the host without updating the hop count (callers can then
pick their own bucket, or all share a proxy's), and a host that is reachable
without going through the proxy while the proxy's address is trusted.

The host says what it decided in its JSON logs:

- `rate_limit_config` at boot: `enabled`, `window_seconds`, `subscribe`,
  `register`, `trusted_networks` (how many ranges), `trusted_proxy_hops` and
  `proxy_auth` (whether the header pair is set). A deploy behind a proxy that
  shows `trusted_networks: 0`, `trusted_proxy_hops: 0` and `proxy_auth: false`
  is running with the shared bucket.
- `rate_limit_untrusted_proxy`, once per process: a request arrived from a
  private address with an `X-Forwarded-For` header and nothing is trusted, which
  is exactly the shared-bucket case. It names the peer.
- `rate_limit_config_warning` at boot, one line per problem: a value that was
  blank, zero or not a number, a list entry dropped, or a header/secret pair with
  only one half set (proxy authentication stays off).

## Seat reads

Two public reads answer how many seats an event has left, so a site never counts
registrations itself. They need no session, carry only counts, and are never rate
limited.

`GET /events/seats` answers every event, keyed by slug:

```json
{
  "events": {
    "yoga": { "capacity": 10, "seats_taken": 4, "seats_left": 6 },
    "retreat": { "capacity": null, "seats_taken": 0, "seats_left": null }
  }
}
```

`GET /events/<slug>/seats` answers one event, with its slug, or `404` with
`{"error": "no such event"}` when there is none. The slug is one non-empty path
segment.

```json
{ "slug": "yoga", "capacity": 10, "seats_taken": 4, "seats_left": 6 }
```

`capacity` and `seats_left` are `null` when the event carries no readable
capacity. `seats_left` is never below zero, even when more seats are taken than
the capacity allows. A read that fails answers `500`.

A registration holds a seat when its payment is `pending`, `succeeded`,
`refunding` or `disputed` and the registration itself is not archived. A
`failed`, `refunded` or `charged_back` payment gives the seat back, and so does
archiving the registration, whatever its payment says; restoring it takes the
seat back. A registration with no payment holds nothing. The same count decides
whether `POST /registrations` refuses a full event, so the read and the refusal
cannot disagree.

An event may also stop taking registrations ahead of its start. When its row
carries both `starts_at` (Unix seconds) and `registration_cutoff_hours` (whole
hours), `POST /registrations` refuses with `422`
`{"error": "registration has closed for this event"}` once the current time plus
the cutoff passes `starts_at`. Registration is still open at exactly the cutoff
and refused one second later; a start already in the past is refused. Each
field may be a bare number or a single-field value object (`{"value": N}`). When
either field is absent, `null` or unreadable there is no cutoff and nothing is
refused on its account. The check runs after the event-status check and before
the seat check, so a refusal writes no Payment and no Registration.
