# test

<!-- prose anchor="Concept" purpose="concept" mentions="command:TestSuiteRun.run_spec_example!" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/test/test.bluebook" -->
Run the specs and the fuzzers. Use it to run one example while you work, or the specs your
change touched.

**Concept.** The test runner runs spec files in this process. `TestSuiteRun.run_spec_example!`
filters to one example by its full description; `run_changed!` runs the specs that the files
changed since a git ref map to.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:TestSuiteRun.run_spec_example! command:TestSuiteRun.run_changed! command:FuzzRun.fuzz!" supports="code_file:lib/hecks/hecks/test/test.bluebook" -->
**Example: run one example**

```sh
hecks TestSuiteRun.run_spec_example! file.value=spec/cli_spec.rb "example.value= "
```

A single space as the example matches every example in the file.

**Example: run the specs your change touched**

```sh
hecks TestSuiteRun.run_changed! base.value=main
```

**Example: fuzz a domain**

```sh
hecks FuzzRun.fuzz! domain.value=examples/banking
```

Fuzzes the domain with generated sequences and keeps whether a property broke.

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks test` prints the same list.

<!-- generated:begin cli section=test -->
### TestSuiteRun

One piece of work on the test suite: a listing, a baseline, a run or a fixture rewrite.

- `hecks TestSuiteRun.run_spec_example! <file> example= [seeds=] [environment=] [tags=] [root=] [--strict] [--declaration-cache]`: Run one spec file filtered to one example, through the test runner in this process
- `hecks TestSuiteRun.run_spec_files! <files> [example=] [isolation=] [seeds=] [environment=] [tags=] [root=] [--strict] [--declaration-cache]`: Run several spec files in one launcher boot, each in a new process or all in one, and report each file
- `hecks TestSuiteRun.run_impacted_specs! [<base>] [cap=] [isolation=] [example=] [seeds=] [environment=] [tags=] [root=] [--dry] [--strict]`: Map the branch's changed files to the specs they touch and run them, or list them when dry
- `hecks TestSuiteRun.run_suite! [<root>] [seeds=] [environment=] [tags=] [--strict]`: Run every spec of a folder through the test runner in this process
- `hecks TestSuiteRun.run_changed! [<root>] [base=] [seeds=] [environment=] [tags=] [--strict]`: Run the specs that the files changed since a git ref map to, in a folder
- `hecks TestSuiteRun.stress_concurrency! [<runs>] [parallel=] [seed_start=]`: Rerun the thread-safety specs under many seeds, several processes at a time
- `hecks TestSuiteRun.run_cargo_tests! <crate> [seeds=] [seed_start=]`: Run the cargo tests of the host, the parser or the JSON fuzzer, with the seed counts their fuzzers take
- `hecks TestSuiteRun.clear_caches!`: Delete the on-disk syntax-boot and verdict caches, so the next boot builds and judges afresh
- `hecks TestSuiteRun.regenerate_legacy_fixtures! --confirm`: Regenerate the persistence legacy fixtures through the real adapters
- `hecks TestSuiteRun.rewrite_ir_golden! --confirm`: Rewrite the frozen IR of the language bluebooks that spec/ir_golden_spec.rb pins, once their source moved
- `hecks TestSuiteRun.seed_semantics_corpus! [<fixture>]`: Fill the expected outcome of every semantics fixture that lacks one, or re-seed one
- `hecks TestSuiteRun.write_io_parallel_spec_list! <exclude> [tags=] write= --confirm`: Write the committed list of the spec files a tag filter selects
- `hecks TestSuiteRun.shard_specs <group> groups= [runtime_log=]`: The spec files one group of a runtime-balanced split runs.
- `hecks TestSuiteRun.list_io_parallel_specs <exclude> [tags=] [check=]`: The spec files with an example a tag filter selects.
- `hecks TestSuiteRun.record_pattern_cases`: The expected match results of the pattern cases, as JSON.

### FuzzRun

One fuzz sweep or benchmark, and how it ended; and the generated sequences it replays.

- `hecks FuzzRun.fuzz! [<domain>] [seeds=] [steps=] [workers=] [adapter=] [shard=] [list_shards=] [--persist-regressions]`: Fuzz a domain with generated sequences and keep whether anything broke a property
- `hecks FuzzRun.mutate! <domain> [seeds=] [steps=] [budget=]`: Mutate a domain's rules and keep whether its checks noticed each change
- `hecks FuzzRun.bench! [<domains>] [targets=] [iterations=] [warmup=] [runs=] [rust_binary=] [format=] [output=]`: Measure command throughput and latency for each target, and keep the report
- `hecks FuzzRun.generate_sequence <domain> [seed=] [steps=] [adversarial=]`: One generated, valid dispatch sequence for a domain, as a script `hecks run` replays. <!-- dead-name-check: skip -->
<!-- generated:end cli -->
