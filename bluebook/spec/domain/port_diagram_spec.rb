require "spec_helper"

RSpec.describe Hecks::DomainVisualizer::PortDiagram do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
      end
    end
  end

  subject(:visualizer) { Hecks::DomainVisualizer.new(domain) }

  let(:extensions) do
    {
      http: { description: "REST server", adapter_type: :driving },
      mcp:  { description: "MCP server", adapter_type: :driving },
      sqlite: { description: "SQLite persistence", adapter_type: :driven },
      auth: { description: "Authorization", adapter_type: :driven }
    }
  end

  let(:output) { visualizer.generate_ports(extensions: extensions) }

  describe "#generate_ports" do
    it "produces a flowchart LR" do
      expect(output).to include("flowchart LR")
    end

    it "groups driving ports in a subgraph" do
      expect(output).to include('subgraph Driving["Driving Ports"]')
      expect(output).to include('port_http["http: REST server"]')
      expect(output).to include('port_mcp["mcp: MCP server"]')
    end

    it "shows the domain hexagon node" do
      expect(output).to include('Domain{{"Pizzas"}}')
    end

    it "groups driven ports in a subgraph" do
      expect(output).to include('subgraph Driven["Driven Ports"]')
      expect(output).to include('port_sqlite["sqlite: SQLite persistence"]')
      expect(output).to include('port_auth["auth: Authorization"]')
    end

    it "draws arrows from driving ports to domain" do
      expect(output).to include("port_http --> Domain")
      expect(output).to include("port_mcp --> Domain")
    end

    it "draws arrows from domain to driven ports" do
      expect(output).to include("Domain --> port_sqlite")
      expect(output).to include("Domain --> port_auth")
    end
  end

  describe "with no extensions" do
    let(:output) { visualizer.generate_ports(extensions: {}) }

    it "still produces a flowchart with the domain node" do
      expect(output).to include("flowchart LR")
      expect(output).to include('Domain{{"Pizzas"}}')
    end

    it "omits port subgraphs" do
      expect(output).not_to include("Driving Ports")
      expect(output).not_to include("Driven Ports")
    end
  end

  describe "with only driving ports" do
    let(:output) do
      visualizer.generate_ports(extensions: { http: { description: "REST", adapter_type: :driving } })
    end

    it "shows driving subgraph but no driven subgraph" do
      expect(output).to include("Driving Ports")
      expect(output).not_to include("Driven Ports")
    end
  end

  describe "with only driven ports" do
    let(:output) do
      visualizer.generate_ports(extensions: { sqlite: { description: "SQLite", adapter_type: :driven } })
    end

    it "shows driven subgraph but no driving subgraph" do
      expect(output).not_to include("Driving Ports")
      expect(output).to include("Driven Ports")
    end
  end

  describe "skips untyped extensions" do
    let(:output) do
      visualizer.generate_ports(extensions: {
        http: { description: "REST", adapter_type: :driving },
        unknown: { description: "Mystery", adapter_type: nil }
      })
    end

    it "does not include untyped extensions" do
      expect(output).not_to include("unknown")
      expect(output).to include("port_http")
    end
  end
end
