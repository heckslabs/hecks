require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/settings_reading"
require_relative "../../support/registry_double"

# `hecks config`'s `disposable ledger` row: whether the world declares its PostgresEra store a
# disposable tooling ledger, and which source said so.
RSpec.describe Hecks::Adapters::SettingsReading, "#settings" do
  include RegistryDouble

  let(:directory) { Dir.mktmpdir("settings-disposable") }
  let(:declared_settings) { {} }

  def line
    text = described_class.new.settings(domain: { value: directory }).fetch(:text)
    text.lines.map(&:chomp).find { |entry| entry.start_with?("disposable ledger: ") }
  end

  before do
    registry = registry_double(first_domain_name: "Shop", binding_settings: declared_settings)
    allow(Hecks).to receive(:describe).with(directory)
                                      .and_return(instance_double(Hecks::Runtime::Loader::Described, registry: registry))
  end

  after { FileUtils.remove_entry(directory) }

  it "says a world that declares nothing keeps its era guard, by default" do
    expect(line).to eq("disposable ledger: no: a shape change needs an era (default)")
  end

  context "when the world declares the ledger disposable" do
    let(:declared_settings) { { disposable_ledger: true } }

    it "says so, and that the world said it" do
      expect(line).to eq("disposable ledger: yes: a shape change needs no era, and a breaking one archives its rows (world)")
    end
  end

  context "when the world declares it false" do
    let(:declared_settings) { { disposable_ledger: false } }

    it "says no, and that the world said it" do
      expect(line).to eq("disposable ledger: no: a shape change needs an era (world)")
    end
  end
end
