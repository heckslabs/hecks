require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "support/client_repo_stub"

# The new-client gate: the Owner opens a client only with the words "new client: <name>", and the
# private repository is then asked for by policy. Any other role, a missing phrase or a phrase
# naming another client is refused and creates nothing. The client is the invented bakery.
module ClientOpenGateWorld
  NAME = YAML.safe_load_file(File.join(InMemoryDomain::ROOT, "spec/fixtures/clients/bakery/bakery.yml"),
                             symbolize_names: true).dig(:client, :name)
  STUB = Hecks::Adapters::ClientRepoStub
  ADAPTER = %(Hecks.adapter "ClientRepoStub" do\n  port "ClientRepo"\nend\n).freeze

  # Boots a copy of the Clients directory with the stub bound, over a fresh stub.
  def booted
    STUB.reset!
    Dir.mktmpdir("hecks-client-open") do |dir|
      FileUtils.cp(Dir[File.join(InMemoryDomain::ROOT, "lib/hecks/clients/clients*")], dir)
      File.write(File.join(dir, "stub.adapter"), ADAPTER)
      yield Hecks.boot(dir, install_driving: false, environment: HecksMemoryEnvironment::NAME)
    end
  end

  # Opens the bakery as the given role, with the given words.
  def open_as(runtime, role, words, named = NAME)
    Hecks::Runtime::Caller.as(role: role) do
      runtime.dispatch_flat("Clients::Client.Open", name: { value: NAME }, phrase: { words: words, named: named })
    end
  end

  # @return [Class] the stub standing for the port
  def stub = STUB

  # @return [String] the invented bakery's name
  def bakery = NAME

  # @return [String] the words the owner says before a client's name
  def words = "new client:"

  # @return [Array<String>] the names of the events recorded so far
  def event_names(runtime) = runtime.events.map(&:name)
end

RSpec.describe "the new-client gate" do
  include ClientOpenGateWorld

  it "creates the bakery's private repository on the owner's words" do
    booted do |runtime|
      open_as(runtime, "Owner", words)
      expect(stub.repos.keys).to eq([bakery])
    end
  end

  it "asks for the repository exactly once" do
    booted do |runtime|
      open_as(runtime, "Owner", words)
      expect(event_names(runtime).count("RepoRequested")).to eq(1)
    end
  end

  it "refuses a coder and creates nothing", :aggregate_failures do
    booted do |runtime|
      expect { open_as(runtime, "Coder", words) }.to raise_error(Hecks::Runtime::Unauthorized)
      expect(stub.repos).to be_empty
    end
  end

  it "refuses an agent and creates nothing", :aggregate_failures do
    booted do |runtime|
      expect { open_as(runtime, "Agent", words) }.to raise_error(Hecks::Runtime::Unauthorized)
      expect(stub.repos).to be_empty
    end
  end

  it "refuses a missing phrase and creates nothing", :aggregate_failures do
    booted do |runtime|
      expect { open_as(runtime, "Owner", "") }.to raise_error(StandardError, /Phrase.words must match/)
      expect(stub.repos).to be_empty
    end
  end

  it "refuses a phrase naming another client and creates nothing", :aggregate_failures do
    booted do |runtime|
      expect { open_as(runtime, "Owner", words, "Someone Else") }
        .to raise_error(StandardError, /the owner said new client: and this client's name/)
      expect(stub.repos).to be_empty
    end
  end

  it "loads no gh adapter in a stub boot" do
    booted do |runtime|
      bound = runtime.registry.adapters.values.select { |adapter| adapter.port == "ClientRepo" }
      expect(bound.map(&:name)).to eq(["ClientRepoStub"])
    end
  end
end
