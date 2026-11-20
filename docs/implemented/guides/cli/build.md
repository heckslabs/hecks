# build

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/build/build.bluebook" -->
Compile a domain and regenerate its output. Use it to build the Rust host for a domain, or to
regenerate the committed Rust output.

**Concept.** A build turns a bluebook into something that runs: a host, a WebAssembly module,
or a browser module. Regeneration rewrites committed output from the bluebooks; you should
never edit that output by hand.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:Build.build_host! command:RegenerationRun.regenerate_corpus!" supports="code_file:lib/hecks/hecks/build/build.bluebook" -->
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

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks build` prints the same list.

<!-- generated:begin cli section=build -->
### Build

One build of a domain for the Rust host, or a check of that build against Ruby.

- `hecks Build.project_rust! <domain>`: Generate a domain's Rust source for the Rust host
- `hecks Build.build_wasm! <domain> [profile=]`: Compile a domain to a WASI module a runtime such as wasmtime can run
- `hecks Build.prune_rust! [<days>] [--dry-run]`: Free the disk Rust builds hold, in gone worktrees and stale cache
- `hecks Build.build_component! <component> [--check]`: Compile an adapter crate to a Wasm component and record its digest
- `hecks Build.build_parser!`: Build the hecks-parse binary the bluebook parser specs run, from rust/parser
- `hecks Build.build_host! <domain> [target=] [stage_dir=] [--prebuilt]`: Build the Rust host for a domain, with its wasm and IR, ready to copy into an image
- `hecks Build.build_browser_wasm! <domain>`: Compile a domain to an ES module a browser can import
- `hecks Build.check_conformance! <domain> script= [artifact=]`: Replay a script through Ruby and a Rust build of the domain and compare what each did
- `hecks Build.fuzz_conformance! <domain> artifact= [seeds=] [steps=]`: Replay generated sequences through Ruby and a Rust build of the domain and compare them
- `hecks Build.check_coverage_allowlist!`: Check that every rule excusing a Rust coverage gap still excuses a real one
- `hecks Build.rust_coverage <module_name> [codegen=]`: Whether each construct of a generated module has a routed Rust implementation.

### RegenerationRun

One regeneration of every corpus domain's committed Rust output, or the check that it is current.

- `hecks RegenerationRun.regenerate_corpus! [domains=] [workers=] [--check] --confirm`: Regenerate the Rust output of every corpus domain or the ones named, or with check only compare it
- `hecks RegenerationRun.project_ci_gates! [--check] --confirm`: Project the CiGate rows into the workflows' marked detector jobs, or with check only compare them
- `hecks RegenerationRun.project_ci_pipeline! [--check] --confirm`: Project the CiWorkflows rows into their workflow files, or with check only compare them
- `hecks RegenerationRun.project_lanes! [--check] [--live] --confirm`: Project the Lane rows into the rulesets and the promotion workflow, or with live compare GitHub's rulesets
- `hecks RegenerationRun.project_agent_roles! [--check] --confirm`: Write .claude/agents from the RoleFile rows of the Role aggregate, and .claude/hooks/guarded_roles from its RoutingRule rows, or with check only compare them
- `hecks RegenerationRun.project_tools_doc! [--check] --confirm`: Write the launcher forms of docs/tools.md from the RetiredScript rows and the command sections of the CLI guides from the module layout, or with check only compare them
- `hecks RegenerationRun.project_glossary! <domain> bluebook= [--check] --confirm`: Write a bluebook's Ubiquitous Language glossary into its domain's glossary folder, or with check only compare it
- `hecks RegenerationRun.decide_ci_gate! <gate>`: Say whether this run's change touches what a CiGate row guards, as the gated job's detector

### KernelRun

One projection of the Rust kernel's capability enums, or one measure of their coverage.

- `hecks KernelRun.project_kernel_capabilities! --confirm`: Project the capability enums the hand-written Rust kernel is matched against
- `hecks KernelRun.measure_kernel_coverage!`: Check that every capability the grammar admits has its hand-written kernel file

### CorpusRun

One look at the corpus and the language's IR, or one server opened on them.

- `hecks CorpusRun.rust_domains`: The feature and directory of every domain with a Rust feature.
- `hecks CorpusRun.regen_order`: The directories regeneration walks, in the order it walks them.
- `hecks CorpusRun.corpus_rust_coverage`: Whether every generated Rust module is routed by its domain.
- `hecks CorpusRun.generated_key [<domains>] [files=]`: The content hash of what regenerating the named domains reads: the generator and each domain's own sources.
- `hecks CorpusRun.ir_constructs [<names>]`: The structural diff of each IR construct from its meta-domain.
- `hecks CorpusRun.ir_duplicates [<domains>] [meta=]`: The rules declared more than once across the corpus.
- `hecks CorpusRun.ir_impact <name> field=`: Which propagation touchpoints of a construct's field already show it.
<!-- generated:end cli -->
