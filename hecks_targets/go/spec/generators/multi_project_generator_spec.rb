require "spec_helper"
require "go_hecks"
require "tmpdir"

RSpec.describe GoHecks::MultiProjectGenerator do
  let(:pizzas_domain) do
    Hecks.domain("Pizzas") do
      aggregate("Pizza") do
        attribute :name, String
        command("CreatePizza") { attribute :name, String }
      end
    end
  end

  let(:orders_domain) do
    Hecks.domain("Orders") do
      aggregate("Order") do
        attribute :quantity, Integer
        command("PlaceOrder") { attribute :quantity, Integer }
      end
    end
  end

  let(:output_dir) { Dir.mktmpdir("go_multi") }
  let(:gen) { described_class.new([pizzas_domain, orders_domain], output_dir: output_dir) }
  let(:root) { gen.generate }

  after { FileUtils.rm_rf(output_dir) }

  describe "project structure" do
    it "creates a multi_domain_static_go root directory" do
      expect(File.directory?(root)).to be true
      expect(root).to end_with("multi_domain_static_go")
    end

    it "generates go.mod with multi_domain module" do
      mod = File.read(File.join(root, "go.mod"))
      expect(mod).to include("module multi_domain")
    end

    it "generates shared runtime" do
      expect(File.exist?(File.join(root, "runtime", "eventbus.go"))).to be true
      expect(File.exist?(File.join(root, "runtime", "commandbus.go"))).to be true
    end

    it "generates cmd/main/main.go" do
      main = File.read(File.join(root, "cmd", "main", "main.go"))
      expect(main).to include("package main")
      expect(main).to include('"multi_domain/server"')
    end
  end

  describe "domain packages" do
    it "generates pizzas package with domain structs" do
      pizza_go = File.read(File.join(root, "pizzas", "pizza.go"))
      expect(pizza_go).to include("package pizzas")
    end

    it "generates orders package with domain structs" do
      order_go = File.read(File.join(root, "orders", "order.go"))
      expect(order_go).to include("package orders")
    end

    it "generates commands in domain-specific packages" do
      cmd = File.read(File.join(root, "pizzas", "create_pizza.go"))
      expect(cmd).to include("package pizzas")
    end

    it "generates errors in each domain package" do
      expect(File.exist?(File.join(root, "pizzas", "errors.go"))).to be true
      expect(File.exist?(File.join(root, "orders", "errors.go"))).to be true
    end
  end

  describe "memory adapters" do
    it "generates adapters under each domain package" do
      adapter = File.read(File.join(root, "pizzas", "adapters", "memory", "pizza_repository.go"))
      expect(adapter).to include("package memory")
      expect(adapter).to include('"multi_domain/pizzas"')
    end

    it "aliases domain import as 'domain' in subdomain adapters" do
      adapter = File.read(File.join(root, "pizzas", "adapters", "memory", "pizza_repository.go"))
      expect(adapter).to include('domain "multi_domain/pizzas"')
    end

    it "generates order adapters under orders package" do
      adapter = File.read(File.join(root, "orders", "adapters", "memory", "order_repository.go"))
      expect(adapter).to include('domain "multi_domain/orders"')
    end
  end

  describe "combined server" do
    let(:server_go) { File.read(File.join(root, "server", "server.go")) }

    it "imports both domain packages" do
      expect(server_go).to include('"multi_domain/pizzas"')
      expect(server_go).to include('"multi_domain/orders"')
    end

    it "imports memory adapters with aliased names" do
      expect(server_go).to include('pizzasmem "multi_domain/pizzas/adapters/memory"')
      expect(server_go).to include('ordersmem "multi_domain/orders/adapters/memory"')
    end

    it "generates App struct with repos from all domains" do
      expect(server_go).to include("pizzasPizzaRepo pizzas.PizzaRepository")
      expect(server_go).to include("ordersOrderRepo orders.OrderRepository")
    end

    it "routes domain aggregates under domain prefix" do
      expect(server_go).to include('GET /pizzas/pizzas')
      expect(server_go).to include('GET /orders/orders')
    end

    it "routes commands under domain prefix" do
      expect(server_go).to include('POST /pizzas/pizzas/create_pizza/submit')
      expect(server_go).to include('POST /orders/orders/place_order/submit')
    end

    it "generates home route listing all domains" do
      expect(server_go).to include('"Pizzas"')
      expect(server_go).to include('"Orders"')
    end
  end

  describe "custom project name" do
    let(:gen) { described_class.new([pizzas_domain, orders_domain], output_dir: output_dir, name: "my_platform") }

    it "uses custom name for directory and module" do
      expect(root).to end_with("my_platform_static_go")
      mod = File.read(File.join(root, "go.mod"))
      expect(mod).to include("module my_platform")
    end
  end
end
