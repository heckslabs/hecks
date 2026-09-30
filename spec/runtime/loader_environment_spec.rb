require "spec_helper"

# The overlay a boot loads is a per-boot choice: an omitted keyword follows
# `HECKS_ENVIRONMENT`, a named one wins, and an explicit nil loads none.
RSpec.describe Hecks::Runtime::Loader, ".selected_environment" do
  around do |example|
    saved = ENV.fetch("HECKS_ENVIRONMENT", nil)
    ENV["HECKS_ENVIRONMENT"] = "memory"
    example.run
  ensure
    ENV["HECKS_ENVIRONMENT"] = saved
  end

  it "follows HECKS_ENVIRONMENT when the caller leaves the keyword at its default" do
    expect(described_class.selected_environment(described_class::FROM_ENV)).to eq("memory")
  end

  it "prefers a named environment over the variable" do
    expect(described_class.selected_environment("staging")).to eq("staging")
  end

  it "loads no overlay for an explicit nil, whatever the variable holds" do
    expect(described_class.selected_environment(nil)).to be_nil
  end

  it "is nil by default when the variable is blank" do
    ENV["HECKS_ENVIRONMENT"] = " "
    expect(described_class.selected_environment(described_class::FROM_ENV)).to be_nil
  end

  it "defaults every public boot entry to the variable" do
    [Hecks.method(:boot), Hecks.method(:boot_files),
     Hecks::Runtime.method(:boot), Hecks::Runtime.method(:boot_files)].each do |entry|
      expect(entry.parameters).to include([:key, :environment])
    end
  end
end
