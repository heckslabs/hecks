require "spec_helper"
require "hecks/chapters"

# `Chapters.load!` brings a gem chapter into the open registry whole or not at all.
RSpec.describe Hecks::Chapters, ".load!" do
  around do |example|
    Hecks.with_registry(Hecks::Runtime::Registry.new) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |path| Kernel.load(path) }
      example.run
    end
  end

  let(:registry) { Hecks.current_registry }
  let(:paths)    { described_class.index.fetch("Deploy") }

  it "leaves no half-loaded chapter behind when a file raises, so a retry loads it" do
    allow(Kernel).to receive(:load).and_wrap_original do |original, path, *rest|
      original.call(path, *rest)
      raise "boom after #{File.basename(path)}" if path == paths.last
    end

    expect { described_class.load!("Deploy") }.to raise_error(/boom after/)
    expect(registry.bluebook("Deploy")).to be_nil
    expect(registry.bluebook_sources).not_to have_key("Deploy")
    expect(Hecks::Bluebook::MetaValidator.deferred_chapters).not_to include("Deploy")

    RSpec::Mocks.space.proxy_for(Kernel).reset
    expect(described_class.load!("Deploy")).to be true
    expect(registry.bluebook("Deploy")).not_to be_nil
  end

  it "returns nil for a chapter it already loaded" do
    described_class.load!("Deploy")

    expect(described_class.load!("Deploy")).to be_nil
  end

  it "raises a WiringError, not a NoMethodError, outside a boot" do
    allow(Hecks).to receive(:current_registry).and_return(nil)

    expect { described_class.load!("Deploy") }
      .to raise_error(Hecks::Runtime::WiringError, /no registry is open/)
  end

  it "refuses a user chapter that shares the attachable chapter's name" do
    Hecks.bluebook("Deploy") do
      aggregate("Session") do
        identified_by :id
        attribute :id, Id
        value_object("Id") { attribute :value, String }
        command("Open") do
          attribute :id, Id
          sets :id
          emits "Opened"
        end
      end
    end

    expect { described_class.load!("Deploy") }
      .to raise_error(Hecks::Runtime::WiringError, /already declared in .*chapters_load_spec/)
  end
end
