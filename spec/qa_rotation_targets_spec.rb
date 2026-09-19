require "spec_helper"
require "hecks/corpus"

# Every domain this repository owns is in the rotation, or nothing sweeps
# it. `bin/qa_seed_targets` carried a hand-typed list naming three of the
# thirteen stress domains; the other ten had never been swept once. They
# were authored, argued for in their own NOTES.md, several promoted by
# `bin/qa_generated_domains --promote` — and invisible to the practice,
# because a `Target` row is what puts a domain in the rotation and
# nothing tied that list to the corpus. `--promote` only ever printed the
# `target.identify` line for a human to run.
#
# The list is derived now, and this file is what keeps it that way: the
# corpus is the oracle, and the seeder is checked for still reading it.
RSpec.describe "the QA rotation's own targets" do
  let(:root) { InMemoryDomain::ROOT }
  let(:targets) { Hecks::Corpus.rotation_targets(root: root) }

  it "holds every example and stress domain the corpus knows, by reference and repo-relative path" do
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

    expect(missing).to be_empty, "these rotation targets hold no bluebook: #{missing.keys.join(', ')}"
  end

  # **The seeder reads the corpus, not a list** — the drift this whole file
  # exists to stop is someone re-typing the membership somewhere. If that
  # happens again it fails here, rather than ten domains later going
  # quietly unswept.
  it "is what bin/qa_seed_targets seeds from" do
    seeder = File.read(File.join(root, "bin/qa_seed_targets"))

    expect(seeder).to match(/SEED\s*=\s*Hecks::Corpus\.rotation_targets/)
  end
end
