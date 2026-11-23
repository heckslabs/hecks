require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"

# The Clients bluebook booted from a copy of lib/hecks/clients beside a stub adapter for its
# ClientRepo port, over the invented bakery fixture. The stub answers private for the names it was
# told and refuses every other, so a missing answer fails closed.
module ClientsSpecWorld
  FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/clients/bakery/bakery.yml")

  ADAPTER = <<~ADAPTER.freeze
    module Hecks
      module Adapters
        class ClientsSpecRepoStub
          PRIVATE = ["Rye and Rosemary Bakery"].freeze

          def initialize(aggregate: nil); end

          def is_private(name:, **)
            raise "the repository is not private" unless PRIVATE.include?(name[:value] || name)

            { name: name }
          end
        end
      end
    end

    Hecks.adapter "ClientsSpecRepoStub" do
      port "ClientRepo"
    end
  ADAPTER

  # @return [Hash] the bakery fixture, as plain data
  def bakery = YAML.safe_load_file(FIXTURE, symbolize_names: true)

  # Boots a copy of the Clients directory, with the stub adapter when asked.
  #
  # @param stub [Boolean] whether the ClientRepo port is bound to the stub
  # @return [Hecks::Runtime] the booted runtime
  def booted(stub: true)
    Dir.mktmpdir("hecks-clients") do |dir|
      FileUtils.cp(Dir[File.join(InMemoryDomain::ROOT, "lib/hecks/clients/clients*")], dir)
      File.write(File.join(dir, "stub.adapter"), ADAPTER) if stub
      yield Hecks.boot(dir, install_driving: false, environment: HecksMemoryEnvironment::NAME)
    end
  end

  # @param runtime [Hecks::Runtime] the booted runtime
  # @return [Hash] the bakery client's stored state, as plain data
  def client_state(runtime)
    aggregate = runtime.registry.bluebook("Clients").aggregate("Client")
    Hecks::Runtime::Value.materialize(runtime.registry.repository("Clients", aggregate).find(bakery[:client][:name]).state)
  end

  # Opens the bakery client and asks for its repository.
  def request_repo(runtime)
    name = { value: bakery[:client][:name] }
    runtime.dispatch_flat("Clients::Client.Open", name: name)
    runtime.dispatch_flat("Clients::Client.RequestRepo", name: bakery[:client][:name])
  end
end

RSpec.describe "the Clients bluebook" do
  include ClientsSpecWorld

  it "opens the bakery client with no repository" do
    booted do |runtime|
      runtime.dispatch_flat("Clients::Client.Open", name: { value: bakery[:client][:name] })
      expect(client_state(runtime)[:status]).to eq("none")
    end
  end

  it "records the repository created once the port answers private" do
    booted do |runtime|
      request_repo(runtime)
      expect(client_state(runtime)[:status]).to eq("created")
    end
  end

  it "falls back to none when the port has no adapter to answer private" do
    booted(stub: false) do |runtime|
      request_repo(runtime)
      expect(client_state(runtime)[:status]).to eq("none")
    end
  end

  it "keeps the board link of the bakery client" do
    booted do |runtime|
      runtime.dispatch_flat("Clients::Client.Open", name: { value: bakery[:client][:name] })
      runtime.dispatch_flat("Clients::Client.LinkBoard", name: bakery[:client][:name], board: { value: bakery[:client][:board] })
      expect(client_state(runtime)[:board]).to eq(value: bakery[:client][:board])
    end
  end

  it "has an engagement cite an interview by reference" do
    booted do |runtime|
      runtime.dispatch_flat("Clients::Client.Open", name: { value: bakery[:client][:name] })
      runtime.dispatch_flat("Clients::Engagement.Begin", reference: { value: bakery[:engagement][:reference] },
                                                          client: bakery[:client][:name],
                                                          interview: { value: bakery[:engagement][:interview] })
      expect(runtime.events.map(&:name)).to include("EngagementBegun")
    end
  end
end
