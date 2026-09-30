# @hecks/client

A small TypeScript client for the body-shaped dispatch protocol a Hecks host
answers. It reads the state of a domain, dispatches commands to it, and turns
the answers into typed values. It has no runtime dependencies and uses the
platform `fetch`, so it needs Node 18 or newer.

Beside the dispatch client it carries the other server-side pieces a site in
front of a host tends to need: a JSON reader that survives a briefly
unavailable upstream (`createResilientFetch`), a client for the host's
payment-connection API (`PaymentsConnection`), and a verifier for the account
token the host signs (`verifyAccountToken`). Each is described below.

The host answers this protocol on any path but `/` when it runs with
`HECKS_SERVE_MODE=1` (`rust/host`). The client posts to `<url>/dispatch`. The
protocol has no authentication: use it server to server on a private network,
never from a browser.

## Install

The package is versioned with the `hecks` gem and published under the `@hecks`
npm scope:

```sh
npm install @hecks/client
```

The `hecks` organization exists on npm, but no version is published yet. Until
the first publish, install from a release tag of the repository instead (the
package lives in `packages/hecks-client`, so use a tool that can install from a
subdirectory, or a tarball built with `npm pack`):

```sh
git clone --branch v<version> https://github.com/heckslabs/hecks.git
cd hecks/packages/hecks-client && npm ci && npm pack
npm install ./hecks-client-<version>.tgz
```

`<version>` is a release of the gem, such as `2.6.0`: the package carries the
same version as the `hecks` gem it was released with, so pick the one matching
the host you talk to.

The package is ESM and ships its type declarations.

## Use

```ts
import { HostClient, text, whole } from "@hecks/client";

const client = new HostClient({
  domain: "Shop",
  url: "http://127.0.0.1:4322",
  role: "Organizer",
});

// Everything the domain holds.
const answer = await client.read();

// One aggregate's states, as [id, state] pairs.
const events = client.instancesOf(answer, "Event").map(([id, state]) => ({
  id,
  name: text(state.name), // {value: "Yoga"} -> "Yoga"
  priceCents: whole(state.price, "cents"), // {cents: 10800} -> 10800
}));

// A command, judged by the state that comes back.
const repriced = await client.apply({
  verb: "Event.Reprice",
  to: "yoga-1",
  with: { price: { cents: 12000 } },
  parse: (answer) => client.instancesOf(answer, "Event"),
  confirm: (states) => states.find(([id]) => id === "yoga-1")?.[1].price?.cents === 12000,
});
```

## Configuration

`new HostClient(options)` (or `createClient(options)`) takes:

| Option | Meaning |
| --- | --- |
| `domain` | The domain's name as its bluebook declares it. Falls back to the `HECKS_DOMAIN` environment variable. Required. |
| `url` | Where the host listens. Trailing slashes are trimmed. Falls back to the `HECKS_SERVICE_URL` environment variable. Required. |
| `role` | The role sent with every command unless a call names its own. The host compares it as a plain string against the roles a command declares. When neither the client nor the call sets one, no role is sent and the host performs no role check. |
| `timeoutMs` | How long one request may take before it counts as unreachable. Defaults to `8000`. |
| `fetch` | The `fetch` to send requests with, for tests or a custom agent. Defaults to the global `fetch`, looked up on each call. |

The environment variables are read once, when the client is constructed. A
missing domain or URL throws a `TypeError`.

## API

`HostClient`

- `domain`, `url`: the resolved configuration.
- `qualify(name)`: places a bare name in the client's domain (`"Event"` becomes `"Shop::Event"`). A name that already contains `::` is returned unchanged.
- `read(): Promise<Answer>`: posts `{"read": true}` and returns everything the domain holds.
- `dispatch(verb, args = {}, to?, role?): Promise<Answer>`: posts one command and returns the raw answer. `verb` is `Aggregate.Verb` or fully qualified. `to` targets an existing instance and is omitted for a command that creates one.
- `apply<T>(command): Promise<T>`: dispatches `command.verb` with `command.with`, `command.to` and `command.role`, reads the answer with `command.parse`, and returns the result when `command.confirm` accepts it. Otherwise it throws `DomainRefusal` built from the answer's last refusal.
- `instancesOf(answer, aggregate): [string, state][]`: the states of one aggregate, bare or qualified name.

Standalone readers, importable without a client:

- `instancesOf(answer, "Domain::Aggregate")`: the same lookup with the aggregate named in full.
- `text(raw): string | null`: a string value object's text, `null` when absent or empty.
- `whole(raw, key): number`: a numeric value object's number under `key` (`"value"`, `"cents"`), `0` when absent.
- `optionalWhole(raw, key): number | null`: like `whole`, but `null` when the attribute was left unset.
- `refusalOf(answer, verb): DomainRefusal`: the domain's own words for why a command changed nothing.

Types and errors: `Answer` (`{ instances?, refusals?, error? }`), `Refusal`
(`{ kind, error }`), `ClientOptions`, `Command<T>`, `DomainRefusal` (has
`kind`), `DomainUnavailable`.

The other exports, by the section that describes them: `createResilientFetch`,
`ResilientFetchError` and the types `ResilientFetch`, `ResilientFetchConfig`,
`ResilientRequest`; `PaymentsConnection`, `pastedKeys`, `savedMessage` and the
types `PaymentConnectionState`, `PaymentMode`, `PaymentStatus`,
`PaymentsConnectionOptions`, `PaymentsResult`, `FormFields`, `PastedKeys`;
`verifyAccountToken`, `accountFromCookieHeader`, `cookieValue`,
`accountToken`, `resolveAccountCookieName`, `DEFAULT_ACCOUNT_COOKIE` and the
types `AccountClaims`, `Clock`, `CookieVerifyOptions`, `VerifyOptions`.

### Why `apply` judges by state

The host answers HTTP 200 whether or not the domain refused, and its
`refusals` list can carry entries replayed from history. A command therefore
counts as done when the state that comes back shows the change, never because
the list is empty or non-empty.

### Errors

- `DomainUnavailable`: the host could not be reached, answered a non-2xx status, did not answer with JSON, or answered `{ "error": ... }`.
- `DomainRefusal`: the domain understood a command and said no (`kind` is the failed rule, such as `GivenNotMet`, and `message` is the domain's wording).

## Reading upstream JSON that may be down: `createResilientFetch`

A site that renders from a service it does not own (a CMS, say) should not
turn that service restarting into an error for every visitor.
`createResilientFetch` reads JSON with two layers of protection: it retries
network errors, timeouts and 502/503/504 with a short backoff, and when the
upstream is still failing (a network error or any 5xx) it answers with the last
good response for that exact URL, from this process's memory. A cold process
has nothing remembered and still throws, so a broken deploy is never masked. A
4xx is a real answer and is never retried or served stale.

```ts
import { createResilientFetch } from "@hecks/client";

const upstream = createResilientFetch();
const page = await upstream.json<Page>("http://cms.internal/api/pages/about", {
  what: 'page "about"',
  source: "the CMS",
});
```

`createResilientFetch(config)` takes `fetch`, `sleep` and `warn` (all
injectable, for tests), `retryDelaysMs` (default `[150, 500]`; its length is the
number of retries), `attemptTimeoutMs` (default `10000`) and `maxRemembered`
(default `200`, the least recently answered URL is dropped first). Each reader
keeps its own memory; `clear()` forgets it.

`json<T>(url, request): Promise<T | null>` takes:

| Field | Meaning |
| --- | --- |
| `what`, `source` | Words for the error message: `Failed to fetch <what> from <source>: <failure>`, thrown as `ResilientFetchError` (its `failure` is the last attempt's reason). |
| `allowStale` | Serve the remembered answer when the upstream is down. Defaults to `true`; turn it off where a stale answer would be acted on. |
| `nullOn404` | Resolve to `null` on a 404 instead of throwing. |
| `retryDelaysMs` | Replaces the configured delays for this call. |
| `headers` | Extra request headers. |
| `private` | The response is for one viewer (a draft read with their cookie): never remembered, and never answered from the remembered public copy of the same URL. |

## Connecting a payment processor: `PaymentsConnection`

A host that serves a domain with a `PaymentConnection` answers a JSON API under
`/payments/connection` (`rust/host/src/payments.rs`). Every route acts as the
person behind the host's account cookie, so each call forwards that person's own
session and the host decides who may do what: an Owner connects and
disconnects, only the platform operator turns real payments on or off.

```ts
import { PaymentsConnection, pastedKeys, savedMessage } from "@hecks/client";

const payments = new PaymentsConnection({
  url: "http://127.0.0.1:4322",
  cookieName: "hecks_session", // the host's HECKS_SESSION_COOKIE; this is its default
});

// `session` is the value of the person's account cookie.
const shown = await payments.show(session);
if (shown.ok) console.log(shown.connection.status, shown.connection.can_manage);

const pasted = pastedKeys(await request.formData()); // {keys} or {error}
if ("keys" in pasted) {
  const saved = await payments.saveKeys(session, pasted.keys);
  if (saved.ok) console.log(savedMessage(saved.connection.display_name, saved.connection.mode));
  else if (saved.status === 401) redirectToSignIn();
  else console.error(saved.error);
}
```

`new PaymentsConnection({ url, cookieName?, timeoutMs?, fetch? })`. Every method
takes the session first and returns `Promise<PaymentsResult>`:

| Method | Route | Who may |
| --- | --- | --- |
| `show(session)` | `GET /payments/connection` | an Owner or the operator |
| `saveKeys(session, { secret_key, publishable_key })` | `POST .../direct` | an Owner |
| `useOwnAccount(session, mode)` | `POST .../direct` with `{ mode }` | an Owner |
| `disconnect(session)` | `POST .../disconnect` | an Owner |
| `enable(session)`, `disable(session)` | `POST .../enable`, `.../disable` | the operator |

`PaymentsResult` is `{ ok: true, status, connection }` or
`{ ok: false, status, error }`. `connection` is a `PaymentConnectionState`
(`status`, `processor`, `label`, `account_ref`, `mode`, `display_name`,
`direct_modes`, `direct`, `can_save_keys`, `can_manage`, `can_enable`); it never
carries a credential. `error` is the host's own sentence (`401` "not logged in",
`403`, `409`, `422` for keys the host rejects) and is `undefined` when the host
sent none, which is what an older host without these routes does by redirecting
to an HTML login page. A host that cannot be reached throws `DomainUnavailable`.
A `session` that is empty or not one cookie value throws `TypeError`.

The host, not this package, decides whether a key is well formed: it checks the
prefixes and that both keys are from the same mode, and answers `422` without
quoting a key. `pastedKeys(form)` only trims the two fields (`secret_key`,
`publishable_key`) of a `FormData` (or anything with `get(name)`) and says in
plain words which one is missing; its errors never repeat a pasted value.
`savedMessage(displayName, mode)` writes the confirmation sentence. Keys go to
the host once and are never stored or logged.

## Verifying the host's account token: `verifyAccountToken`

After a sign-in the host mints a signed claim of who the person is and sets it
as a cookie; `GET /accounts/sso-token` mints a 60-second copy as JSON so
another service can start its own session for the same person. These functions
are the receiving half. They are framework independent, do no I/O, and leave
what to do with the person (find or create a user, start a session) to the
caller.

```ts
import { accountFromCookieHeader, verifyAccountToken } from "@hecks/client";

// A handoff token passed in a URL.
const claims = verifyAccountToken(token, process.env.HOST_SESSION_SECRET!);
if (!claims) return new Response("Invalid or expired token.", { status: 401 });
signInAs(claims.email);

// Or the cookie the host set, on a request to the same site.
const who = accountFromCookieHeader(request.headers.get("cookie"), secret, { cookieName: "site_session" });
```

- `verifyAccountToken(token, secret, opts?): AccountClaims | null`, where `AccountClaims` is `{ email, exp }` (`exp` in Unix seconds). It returns `null`, and never throws, for a malformed token, a signature made with another secret, a missing email or expiry, or an expired token. `opts.now` is the clock (`() => milliseconds`, default `Date.now`). `opts.normalizeEmail` trims and lowercases the email and refuses one that is blank afterwards, for a receiver that stores addresses in that form; the default returns the email exactly as the host signed it. An empty `secret` throws `TypeError`.
- `accountFromCookieHeader(header, secret, opts?)`: reads the account cookie out of a `Cookie` header (`opts.cookieName`, default `hecks_session`) and verifies it.
- `cookieValue(header, name)`: one cookie's value in a `Cookie` header, or `null`.
- `accountToken(secret, email, ttlSeconds, opts?)`: mints a token in the host's format, for tests and stand-in hosts.
- `resolveAccountCookieName(configured?)` and `DEFAULT_ACCOUNT_COOKIE`: the cookie name the host uses for a value of `HECKS_SESSION_COOKIE` (unset or empty means `hecks_session`; an invalid name throws `TypeError`).

The secret is the host's session secret; the receiver must hold the same value.
The format is `rust/host/src/auth.rs`'s `account_token`:
`<payload>.<signature>`, where the payload is the base64url (no padding) of
the JSON `{"email": ..., "exp": <unix seconds>}` and the signature is the
lowercase hex HMAC-SHA256 of the payload as sent. A token is expired once the
current second is past `exp`. The tests pin a known-answer vector that the
host's own unit test (`account_token_matches_the_known_answer_vector`) checks
too.

## Development

```sh
npm ci
npm test              # builds, then runs the hermetic tests (no network)
npm run typecheck
```

The hermetic tests run a protocol scenario against an in-process fake of the
host. `npm run test:contract` runs the same scenario against a live host; see
`test/contract.mjs`. The repository's `client-contract` workflow starts
`rust/host` on the `spec/fixtures/rust_host/checkout_fixture` domain and runs
it. To do the same locally, build that domain with `hecks build_wasm`, start
`rust/host`'s `bootstrap` binary with `HECKS_SERVE_MODE=1`, `HECKS_DOMAIN`,
`HECKS_WASM_PATH`, `HECKS_IR_PATH` and `DATABASE_URL` (a Postgres database), and
run `HECKS_SERVICE_URL=http://127.0.0.1:<port> npm run test:contract`. Add
`HECKS_CONTRACT_PAYMENTS=1` when that host also serves the payment-connection
routes (it started with `HECKS_CHECKOUT_DOMAIN` naming its domain) to check the
`PaymentsConnection` 401 as well; the workflow leaves it off.

## Releasing

The package version equals `Hecks::VERSION` and is released together with the
gem; `spec/hecks_client_version_spec.rb` fails when they differ, and
`hecks publish` (and `hecks publish_gem` on its own) refuses to publish while they do. When
`lib/hecks/version.rb` changes, bump the package in the same change:

```sh
cd packages/hecks-client
npm version <version> --no-git-tag-version   # also updates package-lock.json
```

Pushing the release tag starts `.github/workflows/publish-client.yml`, which
publishes the package with npm trusted publishing: a short-lived identity
token from the workflow run, so no npm token and no one-time code is stored
anywhere. `hecks publish` pushes the tag, publishes the gem, and waits for the
package to appear on npm (`hecks publish --npm-only` waits again after a
re-run; a version npm already has is skipped).

One-time setup, by an owner of the `@hecks` scope, once the package exists:
on npmjs.com, package `@hecks/client` > Settings > Trusted Publisher > GitHub
Actions > organization or user `heckslabs`, repository `hecks`, workflow
filename `publish-client.yml`, environment blank.

The first publish, before that can be configured, and any emergency when CI is
down, is `hecks publish --npm-local`. It publishes from this machine with a
token held in 1Password: the "publish token" field on the "npmjs.com" item in
the Hecks vault (`release/npm_publish.env` names the vault, item and field;
the setup is in the header of `hecks publish`). That token must be a granular
token scoped Read and write to the `@hecks` scope with "Bypass two-factor
authentication" enabled, and short-lived: the account's second factor is a
passkey, so a token that requires a one-time code cannot publish (npm answers
`EOTP`). To publish by hand instead (`prepack` builds `dist/` first):

```sh
npm publish --access public
```

Until the first publish, the tag install above is the way to consume the
package.

The steps as a whole are under "Releasing" in the repository's
`CONTRIBUTING.md`.
