# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/trials"

RSpec.describe Hecks::Adapters::Codebase::Trials::Ledger do
  let(:dir) { Dir.mktmpdir("trials-ledger") }
  let(:ledger) { described_class.new(File.join(dir, "trials.jsonl")) }

  after { FileUtils.rm_rf(dir) }

  it "appends each run and reads back only the rows of the kind asked" do
    ledger.append([{ "kind" => "spec", "subject" => "a" }])
    ledger.append([{ "kind" => "gate-quick", "subject" => "rubocop" }])
    expect(ledger.read("spec")).to eq([{ "kind" => "spec", "subject" => "a" }])
  end

  it "reads only the log's tail, dropping the line the limit cut" do
    stub_const("#{described_class}::READ_BYTES", 40)
    ledger.append(Array.new(5) { |index| { "kind" => "spec", "subject" => "s#{index}" } })
    expect(ledger.read("spec").map { |row| row["subject"] }).to eq(%w[s4])
  end

  it "lives under HECKS_CACHE_DIR when it is named" do
    expect(described_class.path("HECKS_CACHE_DIR" => dir)).to eq(File.join(dir, "trials.jsonl"))
  end
end
