# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# Readers of one shared ledger take turns: the second waits, then answers unknown.
RSpec.describe Hecks::Adapters::PipelineBoard::LedgerGate do
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }
  let(:entered) { Queue.new }
  let(:release) { Queue.new }

  def hold
    thread = Thread.new { described_class.through(:tickets) { (entered << :in) && release.pop } }
    entered.pop
    thread
  end

  def busy_read = described_class.through(:tickets, wait: 0.1) { :late }

  it "lets a reader of no shared ledger straight through" do
    expect(described_class.through(:git, wait: 0) { :answered }).to eq(:answered)
  end

  it "frees the gate once a read is done" do
    described_class.through(:tickets, wait: 0) { 1 }
    expect(described_class.through(:tickets, wait: 0) { 2 }).to eq(2)
  end

  it "frees the gate when the read raises" do
    expect { described_class.through(:jobs, wait: 0) { raise "boom" } }.to raise_error("boom")
  end

  it "answers a second reader unknown while a holder stays in the ledger" do
    thread = hold
    expect { busy_read }.to raise_error(unavailable, /tickets ledger is busy/)
    release << :go
    thread.join
  end

  it "lets a reader in once the holder returns" do
    thread = hold
    release << :go
    thread.join
    expect(described_class.through(:tickets, wait: 0) { :after }).to eq(:after)
  end
end
