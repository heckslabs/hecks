require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"

# `Differential.manifest_partition` — the one place a Ruby/Rust query
# divergence may be tolerated, and only for a verb banking's committed
# manifest.json declares not generated.
RSpec.describe Hecks::Fuzzing::Differential, ".manifest_partition" do
  let(:gaps) do
    Hecks::Fuzzing::RustGapManifest.new(rust_dir: File.join(InMemoryDomain::ROOT, "rust"), feature: "banking")
  end
  let(:declared) { "Banking::Account.OpenForSuspendedCustomers" }

  def partition(ruby_refusals: [], rust_refusals: [], ruby_queries: [], rust_queries: [])
    described_class.manifest_partition(gaps, ruby_refusals: ruby_refusals, rust_refusals: rust_refusals,
                                             ruby_queries: ruby_queries, rust_queries: rust_queries)
  end

  it "drops a declared verb from both sides and records it as skipped" do
    refusal = { "verb" => declared, "kind" => "TypeMismatch", "error" => "anything at all" }
    kept = partition(rust_refusals: [refusal], ruby_queries: [{ "query" => declared, "rows" => [] }])

    expect(kept.values_at(:rust_refusals, :ruby_queries, :stale)).to eq([[], [], []])
    expect(kept[:skipped]).to eq(Set[declared])
  end

  # The whole point of Phase 4: the old filter dropped this row because its
  # error contained "is not generated for this domain". Undeclared, it stays.
  it "keeps an undeclared refusal even when it carries Rust's not-generated wording" do
    undeclared = { "verb" => "Banking::ATMCard.ByFee", "kind" => "TypeMismatch",
                   "error" => "named/declared query \"Banking::ATMCard.ByFee\" is not generated for this domain" }
    kept = partition(rust_refusals: [undeclared])

    expect(kept[:rust_refusals]).to eq([undeclared])
    expect(kept[:skipped]).to be_empty
  end

  it "reports a stale manifest when Rust answers a verb the manifest declares not generated" do
    kept = partition(rust_queries: [{ "query" => declared, "rows" => [] }])

    expect(kept[:stale].map { |d| d[:field] }).to eq(%w[manifest])
    expect(kept[:stale].first[:detail]).to include("per_instance/reference_hop_where")
  end
end
