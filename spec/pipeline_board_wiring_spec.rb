# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_web"

# The wiring diagram: the graph read from a registry's bluebooks, and the two routes that serve it.
RSpec.describe Hecks::Adapters::PipelineWiring do
  def policy(name, heard, reaches) = double(name: name, event_qualifier: heard, reaches: reaches)

  def registry(policies, ports: {}, adapters: {}, owned: [], modules: {})
    tree = double(hecks_name: "LinkedTree", description: "A linked worktree.", lifecycle: nil, queries: [],
                  commands: [double(hecks_name: "Add", goal: "Open a worktree", emits: ["AddRequested"])],
                  ports: owned.map { |name| double(name: name, operations: [], answered_queries: []) })
    rows = modules.map { |name, held| double(name: held, aggregate: name, vision: "") }
    book = double(name: "Hecks", policies: policies, aggregates: [tree], modules: rows)
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

  it "carries what an aggregate declares, for the sidebar", :aggregate_failures do
    details = graph([add])[:nodes].first[:details]
    expect(details[:description]).to eq("A linked worktree.")
    expect(details[:commands]).to eq([{ name: "Add", goal: "Open a worktree", emits: ["AddRequested"] }])
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

    it "serves the agents' page at /agents" do
      expect(fetch("/agents").body).to include("Pipeline Agents")
    end

    it "has no external URL in the agents' page" do
      expect(File.read(Hecks::Adapters::PipelineWeb::AGENTS_PAGE)).not_to match(%r{https?://|//cdn|@import})
    end

    it "serves the shared stream script at /stream.js" do
      expect(fetch("/stream.js").body).to include("boardStream")
    end

    # A browser holds six connections to a host; a stream per page used them all up with three tabs.
    it "opens the event stream only in the shared script", :aggregate_failures do
      pages = %w[PAGE AGENTS_PAGE WIRING_PAGE SEQUENCE_PAGE].map { |name| File.read(Hecks::Adapters::PipelineWeb.const_get(name)) }
      pages.each do |page|
        expect(page).not_to include("new EventSource")
        expect(page).to include('<script src="/stream.js"></script>')
      end
    end

    it "serves the shared answer prompt at /answer.js" do
      expect(fetch("/answer.js").body).to include("boardAnswer")
    end

    it "lets both the board and the agents' page answer a session waiting on you", :aggregate_failures do
      %w[PAGE AGENTS_PAGE].each do |name|
        page = File.read(Hecks::Adapters::PipelineWeb.const_get(name))
        expect(page).to include('<script src="/answer.js"></script>')
        expect(page).to include("boardAnswer.open(")
      end
    end

    it "serves the diagrams' page at /diagrams, showing the wiring and the sequence", :aggregate_failures do
      body = fetch("/diagrams").body
      expect(body).to include("Pipeline Diagrams")
      expect(body).to include('src: "/wiring"', 'src: "/sequence"')
    end

    it "links the board to the diagrams' page instead of embedding them", :aggregate_failures do
      page = File.read(Hecks::Adapters::PipelineWeb::PAGE)
      expect(page).to include('href="/diagrams"')
      expect(page).not_to include("<iframe")
    end

    it "pages the board's sessions, keeping each row's controls", :aggregate_failures do
      page = File.read(Hecks::Adapters::PipelineWeb::PAGE)
      expect(page).to include("const SESSION_PAGE = 15;")
      expect(page).to include('pageBar("sessions", at, list.length, SESSION_PAGE')
    end

    it "shows the board's Sessions panel collapsed until it is opened" do
      expect(File.read(Hecks::Adapters::PipelineWeb::PAGE)).to include('<details class="panel" id="sessions-panel"><summary')
    end

    it "links the board's Agents strip to the agents' page" do
      expect(File.read(Hecks::Adapters::PipelineWeb::PAGE)).to include('href="/agents"')
    end
  end
end
