# test

Run the specs and the fuzzers. Use it to run one example while you work, or the specs your
change touched.

**Concept.** The test runner runs spec files in this process. `TestSuiteRun.run_spec_example!`
filters to one example by its full description; `run_changed!` runs the specs that the files
changed since a git ref map to.

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
