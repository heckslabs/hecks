# build

Compile a domain and regenerate its output. Use it to build the Rust host for a domain, or to
regenerate the committed Rust output.

**Concept.** A build turns a bluebook into something that runs: a host, a WebAssembly module,
or a browser module. Regeneration rewrites committed output from the bluebooks; you should
never edit that output by hand.

**Example: build the host for a domain**

```sh
hecks Build.build_host! domain.value=examples/banking
```

Builds the Rust host with its wasm and IR, ready to copy into an image.

**Example: regenerate every corpus domain's Rust output**

```sh
hecks RegenerationRun.regenerate_corpus! confirm.value=true
```

**Example: check that the output is current**

```sh
hecks RegenerationRun.regenerate_corpus! check.value=true
```

Compares the committed output with what regeneration would write, and writes nothing.
