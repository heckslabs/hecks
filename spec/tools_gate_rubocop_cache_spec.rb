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
end
