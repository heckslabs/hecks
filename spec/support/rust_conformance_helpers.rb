# Shared between spec/rust_conformance_spec.rb (the fixed, hand-authored
# corpus) and spec/rust_conformance_fuzz_spec.rb (PRD 04 — the same
# differential check, run against SequenceGenerator's own randomly
# generated sequences instead). Factored out so the two never drift on
# what "a known, understood boundary, not a bug" means — that judgment is
# real, cited, and earned per case (see rust_conformance_spec.rb's own
# extensive comments on each), and belongs in exactly one place.
module RustConformanceHelpers
  # Built for THIS fixture/sequence's own domain, every time — never found
  # by trusting whatever happens to already sit at
  # rust/target/{release,debug}/rust. See rust_conformance_spec.rb's own
  # comment on `build_rust_for` for why an ambient binary is unsafe to
  # trust here.
  def build_rust_for(domain_feature, rust_dir)
    cargo_toml = File.read(File.join(rust_dir, "Cargo.toml"))
    return nil unless cargo_toml =~ /^#{Regexp.escape(domain_feature)}\s*=\s*\[\]/

    built = system("cargo", "build", "--no-default-features", "--features", domain_feature,
                   chdir: rust_dir, out: File::NULL, err: File::NULL)
    return nil unless built

    binary = File.join(rust_dir, "target", "debug", "rust")
    File.executable?(binary) ? binary : nil
  end

  # `corrects`'s own per-record flag fields (`emitted_<event>`, docs/
  # decisions/0049) are a Rust-only implementation detail riding along
  # with the generic snapshot mechanism — Ruby's own records never carry
  # them (its equivalent, `@registry.event_log`, lives on the REGISTRY,
  # never on a record's own `to_h`). They can surface on ANY comparison
  # surface a raw record reaches through — `instances`, but also
  # `queries` (a query answer embeds the same record shape) — so this
  # walks the whole Rust output recursively rather than special-casing
  # each surface one at a time, the same way `bin/rust_conformance`'s own
  # comment cites `spec/codegen_parity_spec.rb`'s precedent of excluding
  # generator/implementation artifacts from a check that exists to
  # verify BEHAVIOR, not internal representation.
  def strip_emitted_flags!(value)
    case value
    when Hash
      value.reject! { |k, _| k.start_with?("emitted_") }
      value.each_value { |v| strip_emitted_flags!(v) }
    when Array
      value.each { |v| strip_emitted_flags!(v) }
    end
    value
  end

  # See rust_conformance_spec.rb's own extensive comment on this exact
  # exclusion (a cross-domain policy match Ruby's single-process boot
  # delivers in-process but Rust's kernel genuinely cannot know the
  # outcome of yet) — reproduced verbatim, not re-derived, so both specs
  # agree on what a cross-domain reaction even means.
  def cross_domain_policy_names(rust_output)
    rust_output.fetch("cross_domain_reactions").flatten.to_set { |r| r["policy"] }
  end

  # See rust_conformance_spec.rb's own comment on this exact, narrow,
  # cited gap (an argument-check-ordering difference for one malformed-
  # payload shape three fixed fixtures happen to hit).
  def known_reaction_gap?(reaction)
    reaction["policy"] == "FreezeAccountsOnSuspension" &&
      reaction["trigger"] == "Banking::Account.FreezeAccount" &&
      reaction["delivered"] == false
  end

  # THE FIXED CORPUS'S OWN NARROW LIST — found and named by hand against a
  # small, curated set of fixtures. Two entries used to live here, both
  # closed by Phase 10 (equivalence-gap plan) porting a declared `offset`
  # for real, in each case confirmed by re-running `bin/project_rust
  # examples/banking` and re-checking the exact same fixture RED-before/
  # GREEN-after: `Banking::ATMCard.ByFee` (a declared AGGREGATE query's own
  # `offset` — spec/corpus/rust_conformance/named_queries_order_limit.json)
  # and `Banking.ComplianceDashboard` (a declared READ MODEL's own
  # `offset` — spec/corpus/rust_conformance/read_models.json). Empty for
  # now — kept, not deleted, as the place the NEXT real, narrow, curated-
  # corpus gap gets named by hand, the same way these two were.
  KNOWN_REFUSAL_GAP_VERBS = [].freeze

  def known_refusal_gap?(entry)
    KNOWN_REFUSAL_GAP_VERBS.include?(entry.key?("verb") ? entry["verb"] : entry["query"])
  end

  # THE GENERALIZED FORM — PRD 04's own reason this can't just reuse
  # `known_refusal_gap?`'s fixed list: a RANDOMLY generated sequence can
  # reach any structurally-unsupported query/read-model verb the domain
  # declares, not only the two the fixed, hand-picked corpus happens to
  # exercise (`rust/project/queries.rb`'s and `read_models.rb`'s own
  # documented refusal boundary — offset/cursor/group_by/count/median/
  # cross-reference wheres, the whole Phase 10 backlog). Matched by
  # Rust's own EXACT refusal wording for this boundary
  # (`"is not generated for this domain"` — codegen's own literal string,
  # `rust/project/queries.rb`/`read_models.rb`), never by verb name: a
  # verb-name list would need to grow forever as the fuzzer explores
  # further; this message is the one honest signal codegen itself already
  # emits for "I cannot execute this construct at all," matching
  # rust_conformance_spec.rb's own "a named/declared query step whose
  # shape this generator doesn't cover still refuses cleanly" example
  # verbatim.
  STRUCTURAL_REFUSAL_MARKER = "is not generated for this domain"

  def structural_refusal_gap?(entry)
    (entry["error"] || "").include?(STRUCTURAL_REFUSAL_MARKER)
  end
end
