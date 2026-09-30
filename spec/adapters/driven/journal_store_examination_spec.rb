require "spec_helper"
require "digest"
require "json"
require_relative "../../../lib/hecks/hecks/adapters/journal_store"

# The facts JournalStore reports about a held era's text, for `Era.Permit`'s re-attestation givens.
# No database is needed: the era is the row `raw_era` would have read.
RSpec.describe Hecks::Adapters::JournalStore::Examination do
  subject(:store) { Hecks::Adapters::JournalStore.new }

  let(:held) do
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind
          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    BLUEBOOK
  end
  let(:shape) do
    Hecks::Translation::Reattest.shadow(held).then do |bluebook|
      JSON.generate(Hecks::Runtime::StorageShape.project(bluebook))
    end
  end

  def era(text, digest_of: held, projection: shape)
    { held_text: text, held_digest: Digest::SHA256.hexdigest(digest_of), hash: nil, held_projection: projection }
  end

  def facts_for(era) = store.send(:text_facts, era)

  it "reports nothing for a text that still matches its digest, so no shape is examined" do
    expect(facts_for(era(held))).to eq({})
  end

  it "reports a drifted text that loads and keeps the shape when only a comment was added" do
    edited = "# a comment added by hand\n#{held}"

    expect(facts_for(era(edited))).to eq(drifted: true, loadable: true, shape_kept: true)
  end

  it "reports a drifted text whose shape changed" do
    changed = held.sub("attribute :kind, Kind", "attribute :kind, Kind\n    attribute :note, Kind")

    expect(facts_for(era(changed))).to eq(drifted: true, loadable: true, shape_kept: false)
  end

  it "reports a drifted text that does not load as a bluebook" do
    broken = "Hecks.bluebook \"Ledger\" do\n  ((((\nend\n"

    expect(facts_for(era(broken))).to eq(drifted: true, loadable: false, shape_kept: false)
  end

  it "treats a drifted text of an era that was never named as a kept shape, to be read carefully" do
    edited = "# a comment added by hand\n#{held}"

    expect(facts_for(era(edited, projection: nil))).to eq(drifted: true, loadable: true, shape_kept: true)
  end

  it "starts every text fact false, so a change that never asks for them is not held to them" do
    neutral = described_class::NEUTRAL

    expect(neutral.values_at(:drifted, :loadable, :shape_kept)).to eq([false, false, false])
  end
end
