# Cross-Target Parity Testing

The parity spec proves that the Ruby static and Go targets produce identical event logs
when given the same command sequence. It builds both targets from the Pizzas domain IR,
boots them as HTTP servers, submits form commands to each, and compares `/_events`.

## Running the spec

```bash
bundle exec rspec hecksties/spec/cross_target_parity_spec.rb --tag parity
```

Expected output:

```
Run options: include {:parity=>true}

Cross-target behavioral parity: Ruby vs Go
  produces identical event name lists after the same command sequence

1 example, 0 failures
```

## How it works

1. `Hecks.build_static(domain, ...)` generates a self-contained Ruby gem with HTTP server
2. `Hecks.build_go(domain, ...)` generates a Go project with HTTP server
3. Both servers are started on random ports
4. `submit_form` GETs each form page, extracts the `action` URL, and POSTs form data
5. `/_events` is fetched from both; names are sorted and compared

## Default run exclusion

The spec is tagged `:parity` and excluded from the default run via `.rspec`:

```
--tag ~parity
```

This keeps the default suite under 1 second. The parity spec itself runs in ~1s
(builds are cached by the Go toolchain).
