require "spec_helper"
require_relative "support/boot_notice_samples"

# A refusal says what the command said first. The runtime's own boot notices (a process manager
# with no `save_saga`, an outbox row claimed before a crash, a worktree without the overlay
# files) follow it after a divider, so the first line is the cause and nothing is lost.
RSpec.describe Hecks::BootNotices do
  include BootNoticeSamples

  def composed(notice) = described_class.compose("#{notice}\n#{refusal}\n")

  it "names the notices", :aggregate_failures do
    expect(described_class.name_of(saga)).to eq(:saga_durability)
    expect(described_class.name_of(outbox)).to eq(:outbox_claimed)
    expect(described_class.name_of(overlay)).to eq(:worktree_overlay)
    expect(described_class.name_of(refusal)).to be_nil
  end

  %i[saga outbox overlay].each do |which|
    it "leads with the refusal and keeps the #{which} notice after the divider", :aggregate_failures do
      text = composed(public_send(which))

      expect(text.lines.first.chomp).to eq(refusal)
      expect(text).to include(described_class::DIVIDER, public_send(which))
    end
  end

  it "keeps every notice, in order, after one divider", :aggregate_failures do
    text = described_class.compose([saga, refusal, outbox, overlay].join("\n"))

    expect(text.scan(described_class::DIVIDER).size).to eq(1)
    expect(text.lines.map(&:chomp)).to eq([refusal, described_class::DIVIDER, saga, outbox, overlay])
  end

  it "answers the notices alone when the command said nothing else" do
    expect(described_class.compose("#{saga}\n#{overlay}\n")).to eq("#{saga}\n#{overlay}")
  end

  it "leaves a command's own words unchanged when there are no notices" do
    expect(described_class.compose("page\nnotice\n")).to eq("page\nnotice")
  end

  it "composes a composed text to itself" do
    once = composed(saga)

    expect(described_class.compose(once)).to eq(once)
  end

  it "reads the cause on one line, the notices only when there is no cause", :aggregate_failures do
    expect(described_class.cause(composed(saga))).to eq(refusal)
    expect(described_class.cause("#{saga}\n")).to eq(saga)
  end
end
