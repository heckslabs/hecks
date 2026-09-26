# @hecks/client

A small TypeScript client for the body-shaped dispatch protocol a Hecks host
answers. It reads the state of a domain, dispatches commands to it, and turns
the answers into typed values. It has no runtime dependencies and uses the
platform `fetch`, so it needs Node 18 or newer.

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

Until the scope is confirmed, install from a release tag of the repository
instead (the package lives in `packages/hecks-client`, so use a tool that can
install from a subdirectory, or a tarball built with `npm pack`):

```sh
git clone --branch v2.5.1 https://github.com/heckslabs/hecks.git
cd hecks/packages/hecks-client && npm ci && npm pack
npm install ./hecks-client-2.5.1.tgz
```

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

### Why `apply` judges by state

The host answers HTTP 200 whether or not the domain refused, and its
`refusals` list can carry entries replayed from history. A command therefore
counts as done when the state that comes back shows the change, never because
the list is empty or non-empty.

### Errors

- `DomainUnavailable`: the host could not be reached, answered a non-2xx status, did not answer with JSON, or answered `{ "error": ... }`.
- `DomainRefusal`: the domain understood a command and said no (`kind` is the failed rule, such as `GivenNotMet`, and `message` is the domain's wording).

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
it. To do the same locally, build that domain with `bin/project_wasm`, start
`rust/host`'s `bootstrap` binary with `HECKS_SERVE_MODE=1`, `HECKS_DOMAIN`,
`HECKS_WASM_PATH`, `HECKS_IR_PATH` and `DATABASE_URL` (a Postgres database), and
run `HECKS_SERVICE_URL=http://127.0.0.1:<port> npm run test:contract`.

The package version equals `Hecks::VERSION` and is released together with the
gem; `spec/hecks_client_version_spec.rb` fails when they differ.
