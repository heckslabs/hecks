# frozen_string_literal: true

require "spec_helper"
require "hecks/tools/gate"

RSpec.describe Hecks::Tools::Gate, ".run_one" do
  it "points each check at one cache directory under the home directory" do
    expect(described_class::RUBOCOP_CACHE_ROOT).to eq(File.join(Dir.home, ".cache", "hecks", "rubocop"))
  end

  it "hands the cache root to a check's process" do
    out, passed = described_class.run_one({ "run" => ["sh", "-c", "printf %s \"$RUBOCOP_CACHE_ROOT\""] }, {}, Dir.pwd)
    expect([out, passed]).to eq([ENV.fetch("RUBOCOP_CACHE_ROOT", described_class::RUBOCOP_CACHE_ROOT), true])
  end

  describe "caller naming" do
    let(:printer) { { "run" => ["sh", "-c", "printf %s \"$HECKS_CALLER\""] } }

    def caller_of_check(caller_value)
      previous = ENV.fetch("HECKS_CALLER", nil)
      ENV["HECKS_CALLER"] = caller_value
      described_class.run_one(printer, {}, Dir.pwd).first
    ensure
      ENV["HECKS_CALLER"] = previous
    end

    it "names the gate as the caller when no session is named" do
      expect(caller_of_check(nil)).to eq("gate")
    end

    it "keeps the session's own name in front of the gate" do
      expect(caller_of_check("coder:run-7")).to eq("coder:run-7:gate")
    end
  end
end
