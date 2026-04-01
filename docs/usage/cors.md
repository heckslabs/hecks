# CORS Configuration

Hecks HTTP servers (`DomainServer`, `RpcServer`, `MultiDomainServer`) do **not**
emit `Access-Control-Allow-Origin` by default. Cross-origin access is opt-in via
environment variables.

## Environment variables

| Variable | Value | Behaviour |
|---|---|---|
| `HECKS_ALLOW_ALL_ORIGINS` | `true` | Emits `Access-Control-Allow-Origin: *` |
| `HECKS_CORS_ORIGIN` | e.g. `https://app.example.com` | Emits that exact value |
| (neither set) | — | Header is not emitted |

`HECKS_ALLOW_ALL_ORIGINS` takes precedence. If both are set, `*` is emitted.

## Before (always open)

Previously every response included:

```
Access-Control-Allow-Origin: *
```

regardless of deployment context.

## After (opt-in)

```bash
# Allow all origins (development / public APIs)
HECKS_ALLOW_ALL_ORIGINS=true hecks serve pizzas_domain

# Allow a specific origin (production)
HECKS_CORS_ORIGIN=https://app.example.com hecks serve pizzas_domain

# No CORS header — same-origin only (default)
hecks serve pizzas_domain
```

## How it works

All three servers include `Hecks::HTTP::CorsHeaders` and call
`apply_cors_origin(res)` at the top of each request handler. The method reads
the ENV variables once per request and sets the header only when a value is
present.
