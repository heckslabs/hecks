# Specs for ActiveHecks::Railtie
#
# Verifies that the railtie registers itself correctly and that the
# active_hecks.setup initializer boots the configuration when present.
#
require_relative "../spec_helper"
require "active_hecks/railtie"

RSpec.describe "ActiveHecks::Railtie" do
  it "exists as a subclass of the stubbed Rails::Railtie" do
    expect(ActiveHecks::Railtie.ancestors).to include(Rails::Railtie)
  end

  describe "initializer active_hecks.setup" do
    let(:initializer_entry) do
      ActiveHecks::Railtie._initializers.find { |i| i[:name] == "active_hecks.setup" }
    end

    it "is registered" do
      expect(initializer_entry).not_to be_nil
    end

    it "calls boot! when configuration is present" do
      config = instance_double(Hecks::Configuration, boot!: nil)
      allow(Hecks).to receive(:configuration).and_return(config)

      expect(config).to receive(:boot!).once
      initializer_entry[:block].call
    end

    it "is a no-op when configuration is nil" do
      allow(Hecks).to receive(:configuration).and_return(nil)

      expect { initializer_entry[:block].call }.not_to raise_error
    end

    it "calls boot! exactly once" do
      config = instance_double(Hecks::Configuration, boot!: nil)
      allow(Hecks).to receive(:configuration).and_return(config)

      expect(config).to receive(:boot!).exactly(1).times
      initializer_entry[:block].call
    end
  end
end
