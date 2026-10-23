require "spec_helper"
require "tmpdir"

# A starting world is read off what each bound adapter declares; it never holds a secret's value.
RSpec.describe Hecks::Projections::WorldSkeleton do
  DECLARE_SKEL_DOMAIN = lambda do
    Hecks.bluebook "Skel" do
      aggregate "Thing" do
        identified_by :id
        attribute :id, Id

        value_object "Id" do
          attribute :value, String
          invariant("an id is present") { !value.to_s.empty? }
        end

        command "Make" do
          goal "make a thing"
          attribute :id, Id
          sets :id
          emits "ThingMade"
        end
      end
    end
  end

  DECLARE_SKEL_ADAPTER = lambda do
    Hecks.adapter "SkelStore" do
      port "persistence"
      field :dir, default: "data"
      field :host
      secret :api_token
    end
  end

  def registry_binding(adapter)
    Hecks::Runtime::Registry.new.tap do |registry|
      Hecks.with_registry(registry) do
        MemoryPorts.load!
        DECLARE_SKEL_DOMAIN.call
        DECLARE_SKEL_ADAPTER.call
        Hecks.hecksagon("Skel") { Skel::Thing.persisted_by(adapter) }
      end
    end
  end

  def loaded_settings(text)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "skel.world"), text)
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { Kernel.load(File.join(dir, "skel.world")) }
      registry.world("Skel").for_binding("persisted_by", "SkelStore")
    end
  end

  let(:skeleton) { described_class.call(registry: registry_binding("SkelStore")) }

  it "lists a field's default as a comment and a field without one as a comment to set" do
    expect(skeleton).to include('# dir "data"', '# host "..."')
  end

  it "writes a secret as an environment lookup and never as a value" do
    expect(skeleton).to include('api_token ENV.fetch("SKEL_API_TOKEN", "")')
  end

  it "says no world is needed when every bound adapter declares nothing" do
    expect(described_class.call(registry: registry_binding("Memory"))).to eq(described_class::NONE)
  end

  it "loads back as a world that carries the secret and none of the commented fields" do
    expect(loaded_settings(skeleton)).to eq(adapter: "SkelStore", api_token: "")
  end
end
