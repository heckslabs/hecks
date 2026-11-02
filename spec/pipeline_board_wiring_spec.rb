# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_web"

# The wiring diagram: the graph read from a registry's bluebooks, and the two routes that serve it.
RSpec.describe Hecks::Adapters::PipelineWiring do
  def policy(name, heard, reaches) = double(name: name, event_qualifier: heard, reaches: reaches)

  def registry(policies, ports: {}, adapters: {}, owned: [], modules: {})
    aggregate = double(ports: owned.map { |name| double(name: name) })
    rows = modules.map { |name, held| double(name: held, aggregate: name) }
    book = double(name: "Hecks", policies: policies, aggregates: [aggregate], modules: rows)
    instance_double(Hecks::Runtime::Registry, bluebooks: { "Hecks" => book }, ports: ports, adapters: adapters)
  end

  def graph(policies, **wiring) = described_class.new(registry: registry(policies, **wiring)).graph

  let(:add) { policy("AddWorktreeWhenRequested", "LinkedTree", "Hecks::LinkedTree::WorktreeAdding.Create") }

  it "draws a policy as an edge between the aggregate it hears and the one it reaches", :aggregate_failures do
    found = graph([add])
    edge = { from: "Hecks::LinkedTree", to: "Hecks::LinkedTree", label: "AddWorktreeWhenRequested", kind: "policy" }
    expect(found[:edges]).to eq([edge])
    expect(found[:nodes].map { |node| node[:id] }).to eq(["Hecks::LinkedTree"])
  end

  it "draws an ask as an edge to its port, and the port to the adapter that answers it", :aggregate_failures do
    ask = policy("ListenWhenServed", "PipelineBoard", "Hecks::PipelineBoard::Web.Listen")
    adapter = double(name: "PipelineWeb", port_name: "Web")
    found = graph([ask], ports: { "Web" => :port }, adapters: { "PipelineWeb" => adapter })
    expect(found[:edges].map { |edge| edge[:kind] }).to eq(%w[ask adapter])
    expect(found[:nodes].map { |node| node[:kind] }.sort).to eq(%w[adapter aggregate port])
  end

  it "puts a port in the domain of the aggregate that asks through it" do
    ask = policy("ListenWhenServed", "PipelineBoard", "Hecks::PipelineBoard::Web.Listen")
    port = graph([ask], ports: { "Web" => :port })[:nodes].find { |node| node[:kind] == "port" }
    expect(port).to include(domain: "Hecks", label: "Web")
  end

  it "finds a port an aggregate declares for itself, not only the registry's" do
    ask = policy("FetchWhenChecked", "Host", "Hecks::Host::HostHttp.Fetch")
    expect(graph([ask], owned: ["HostHttp"])[:edges].map { |edge| edge[:to] }).to eq(["port:HostHttp"])
  end

  it "names the module an aggregate is declared in, and gives its port the same", :aggregate_failures do
    ask = policy("ListenWhenServed", "PipelineBoard", "Hecks::PipelineBoard::Web.Listen")
    found = graph([ask], ports: { "Web" => :port }, modules: { "PipelineBoard" => "Serve" })
    expect(found[:nodes].map { |node| node[:context] }).to eq(%w[Serve Serve])
  end

  it "leaves out an aggregate that nothing is wired to" do
    expect(graph([])[:nodes]).to be_empty
  end

  it "says why when no registry is booted here" do
    expect { described_class.new.graph }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /no domain is booted/)
  end

  describe "served over a real socket" do
    let(:server) { web.open_at(0) }

    def web
      wiring = described_class.new(registry: registry([add]))
      Hecks::Adapters::PipelineWeb.new(settings: { stages: nil, wiring: wiring, background: false })
    end

    after { server.stop }

    def fetch(path) = Net::HTTP.start("127.0.0.1", server.port) { |http| http.get(path) }

    it "answers /api/wiring with the graph" do
      expect(JSON.parse(fetch("/api/wiring").body)["nodes"].size).to eq(1)
    end

    it "serves the diagram page at /wiring" do
      expect(fetch("/wiring").body).to include("Pipeline Wiring")
    end

    it "has no external URL in the diagram page" do
      expect(File.read(Hecks::Adapters::PipelineWeb::WIRING_PAGE)).not_to match(%r{https?://|//cdn|@import})
    end

    it "serves the sequence diagram at /sequence" do
      expect(fetch("/sequence").body).to include("Pipeline Sequence")
    end

    it "has no external URL in the sequence page" do
      expect(File.read(Hecks::Adapters::PipelineWeb::SEQUENCE_PAGE)).not_to match(%r{https?://|//cdn|@import})
    end
  end
end
