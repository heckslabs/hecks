require "spec_helper"
require "go_hecks"

RSpec.describe GoHecks::ServerGenerator do
  let(:domain) do
    Hecks.domain("Pizzas") do
      aggregate("Pizza", "Classic Italian pies") do
        attribute :name, String
        command("CreatePizza") { attribute :name, String }
        command("UpdatePizza") { attribute :pizza, String; attribute :name, String }
      end
    end
  end

  let(:server) { GoHecks::ServerGenerator.new(domain, module_path: "pizzas_domain") }
  let(:output) { server.generate }

  describe "index route" do
    it "generates GET handler for aggregate list" do
      expect(output).to include('mux.HandleFunc("GET /pizzas"')
    end

    it "includes description in index data" do
      expect(output).to include('Description: "Classic Italian pies"')
    end

    it "generates column and item structs" do
      expect(output).to include("type PizzaCol struct")
      expect(output).to include("type PizzaItem struct")
      expect(output).to include("type PizzaIndexData struct")
    end
  end

  describe "find route" do
    it "generates GET find handler" do
      expect(output).to include('mux.HandleFunc("GET /pizzas/find"')
    end
  end

  describe "command routes" do
    it "generates POST handler per command" do
      expect(output).to include('mux.HandleFunc("POST /pizzas/create_pizza"')
      expect(output).to include('mux.HandleFunc("POST /pizzas/update_pizza"')
    end

    it "decodes JSON and form submissions" do
      expect(output).to include("json.NewDecoder(r.Body).Decode(&cmd)")
      expect(output).to include("r.ParseForm()")
    end

    it "re-renders form with error message on validation failure instead of raw http.Error 422" do
      expect(output).not_to include("http.Error(w, err.Error(), 422)")
      expect(output).to include("ErrorMessage: err.Error()")
      expect(output).to include('renderer.Render(w, "form"')
      expect(output).to include("w.WriteHeader(422)")
    end

    it "preserves submitted field values in error re-render using r.FormValue" do
      expect(output).to include('Value: r.FormValue("name")')
    end
  end

  describe "show route" do
    it "generates GET show handler" do
      expect(output).to include('mux.HandleFunc("GET /pizzas/show"')
    end

    it "generates field and show data structs" do
      expect(output).to include("type PizzaField struct")
      expect(output).to include("type PizzaShowData struct")
    end
  end

  describe "cross-aggregate command buttons on show page" do
    let(:domain) do
      Hecks.domain("Store") do
        aggregate("Product") do
          attribute :name, String
          command("CreateProduct") { attribute :name, String }
        end
        aggregate("Review") do
          attribute :body, String
          command("CreateReview") { attribute :product_id, String; attribute :body, String }
        end
      end
    end

    let(:server) { GoHecks::ServerGenerator.new(domain, module_path: "store_domain") }
    let(:output) { server.generate }

    it "renders cross-aggregate Create Review button on Product show page" do
      expect(output).to include('Label: "Create Review"')
    end

    it "links cross-aggregate button to the other aggregate's form with id param" do
      expect(output).to include('/reviews/create_review/new?id=')
    end
  end

  describe "nav items" do
    it "does not include duplicate Home entry" do
      expect(output.scan('"Home"').size).to eq(0)
    end

    it "includes aggregate nav items with group" do
      expect(output).to include('{Label: "Pizzas", Href: "/pizzas"')
    end
  end
end
