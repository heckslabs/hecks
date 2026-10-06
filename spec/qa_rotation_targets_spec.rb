require "spec_helper"
require "hecks/corpus"

# Every example and stress domain in the corpus must be a rotation target, or nothing
# sweeps it. The corpus is the oracle; the seeder must read it rather than a typed list.
RSpec.describe "the QA rotation's own targets" do
  let(:root) { InMemoryDomain::ROOT }
  let(:targets) { Hecks::Corpus.rotation_targets(root: root) }

  it "holds every example and stress domain the corpus knows, by reference and repo-relative path", :aggregate_failures do
    expected = Hecks::Corpus.members(:example, :stress, root: root)
                            .to_h { |member| [member.stem, member.path.delete_prefix("#{root}/")] }

    expect(targets).to include(expected)
    expect(targets.keys).to include("case_escalation", "corrections", "tenant_ledger", "referral_chain")
  end

  it "sweeps the ledger itself, the one member that is neither" do
    expect(targets["quality_control"]).to eq("qa/bluebook")
  end

  it "names a path that really holds a bluebook, for every one of them" do
    missing = targets.reject { |_, path| Hecks::Corpus.bluebook_files(File.join(root, path)) }

    expect(missing).to be_empty, "these rotation targets hold no bluebook: #{missing.keys.join(", ")}"
  end

  # Fails if someone re-types the membership in the seeder instead of reading the corpus.
  it "is what qa_seed_targets seeds from" do
    seeder = File.read(File.join(root, "lib/hecks/quality_control/cli/qa_seed_targets.rb"))

    expect(seeder).to match(/seed\s*=\s*Hecks::Corpus\.rotation_targets/)
  end
end
