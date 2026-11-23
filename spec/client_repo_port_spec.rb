require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "support/client_repo_stub"

# The ClientRepo port, seen from the Clients bluebook with the stub bound: the repository is created
# private, a file is written only after the repository is read as private, and one found public
# is refused and recorded as a finding inside Clients. The client is the invented bakery.
module ClientRepoPortWorld
  NAME = YAML.safe_load_file(File.join(InMemoryDomain::ROOT, "spec/fixtures/clients/bakery/bakery.yml"),
                             symbolize_names: true).dig(:client, :name)
  STUB = Hecks::Adapters::ClientRepoStub
  ADAPTER = %(Hecks.adapter "ClientRepoStub" do\n  port "ClientRepo"\nend\n).freeze

  # Boots a copy of the Clients directory with the stub bound, over a fresh stub.
  def booted
    STUB.reset!
    Dir.mktmpdir("hecks-client-repo") do |dir|
      FileUtils.cp(Dir[File.join(InMemoryDomain::ROOT, "lib/hecks/clients/clients*")], dir)
      File.write(File.join(dir, "stub.adapter"), ADAPTER)
      yield Hecks.boot(dir, install_driving: false, environment: HecksMemoryEnvironment::NAME)
    end
  end

  # Opens the bakery, asks for its repository and has the first call's notes written.
  def write_notes(runtime, content: "the first call")
    runtime.dispatch_flat("Clients::Client.Open", name: { value: bakery })
    runtime.dispatch_flat("Clients::Client.RequestRepo", client: bakery)
    runtime.dispatch_flat("Clients::Client.WriteRepoFile", client: bakery, path: { value: "notes/call.md" },
                                                           content: { value: content })
  end

  # Opens the bakery, has its repository made, finds it public and asks for a file to be written.
  def write_to_public(runtime)
    runtime.dispatch_flat("Clients::Client.Open", name: { value: bakery })
    runtime.dispatch_flat("Clients::Client.RequestRepo", client: bakery)
    stub.visibility = "public"
    runtime.dispatch_flat("Clients::Client.WriteRepoFile", client: bakery, path: { value: "a.md" },
                                                           content: { value: "x" })
  end

  # @return [Class] the stub standing for the port
  def stub = STUB

  # @return [String] the invented bakery's name
  def bakery = NAME

  # @return [Array<String>] the names of the events recorded so far
  def event_names(runtime) = runtime.events.map(&:name)
end

RSpec.describe "the ClientRepo port" do
  include ClientRepoPortWorld

  it "has the stub record a file written to the bakery's private repository" do
    booted do |runtime|
      write_notes(runtime)
      expect(stub.repos.dig(bakery, "notes/call.md")).to eq("the first call")
    end
  end

  it "records the file written as an event of the client" do
    booted do |runtime|
      write_notes(runtime)
      expect(event_names(runtime)).to include("RepoFileWritten")
    end
  end

  it "refuses a write to a repository found public, and records the finding" do
    booted do |runtime|
      write_to_public(runtime)
      expect(event_names(runtime)).to include("RepoFoundPublic")
    end
  end

  it "writes nothing to a repository found public" do
    booted do |runtime|
      write_to_public(runtime)
      expect(stub.repos.fetch(bakery)).to be_empty
    end
  end

  it "binds no gh adapter in a stub boot" do
    booted do |runtime|
      bound = runtime.registry.adapters.values.select { |adapter| adapter.port == "ClientRepo" }
      expect(bound.map(&:name)).to eq(["ClientRepoStub"])
    end
  end

  it "lets no ask of the port carry a visibility" do
    ports = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/clients/clients.ports.hecksagon"))
    expect(ports.scan(/attribute :(\w+)/).flatten & %w[visibility private public]).to be_empty
  end
end
