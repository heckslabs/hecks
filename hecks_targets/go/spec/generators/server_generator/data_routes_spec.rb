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
      expect(output).to include("type PizzaColumn struct")
      expect(output).to include("type PizzaIndexItem struct")
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
      expect(output).to include('mux.HandleFunc("POST /pizzas/create_pizza/submit"')
      expect(output).to include('mux.HandleFunc("POST /pizzas/update_pizza/submit"')
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
      expect(output).to include("type PizzaShowField struct")
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

  describe "reference column name lookup (HEC-239)" do
    let(:domain) do
      Hecks.domain("Store") do
        aggregate("Product") do
          attribute :name, String
          command("CreateProduct") { attribute :name, String }
        end
        aggregate("Review") do
          attribute :body, String
          attribute :product_id, String
          command("CreateReview") { attribute :product_id, String; attribute :body, String }
        end
      end
    end

    let(:server) { GoHecks::ServerGenerator.new(domain, module_path: "store_domain") }
    let(:output) { server.generate }

    it "labels reference column as entity name without Id suffix" do
      expect(output).to include('{Label: "Product"}')
    end

    it "builds a name-lookup map for the referenced aggregate" do
      expect(output).to include("productNames := map[string]string{}")
      expect(output).to include("app.ProductRepo.All()")
    end

    it "uses the lookup map in cell expression" do
      expect(output).to include("productNames[obj.ProductId]")
    end
  end

  describe "home page command names (HEC-242)" do
    it "includes command names in home aggregate data" do
      expect(output).to include('CommandNames: "Create Pizza, Update Pizza"')
    end

    it "generates HomeAgg struct with CommandNames field" do
      expect(output).to include("type HomeAgg struct")
      expect(output).to include("CommandNames string")
    end
  end

  describe "cross-aggregate buttons negative case (HEC-258)" do
    it "does not add cross-aggregate buttons when no references exist" do
      # The basic pizza domain has no cross-aggregate references
      # so there should be no `buttons = append(buttons,` calls
      expect(output).not_to include("buttons = append(buttons,")
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

  describe "CSRF protection" do
    it "generates csrfToken helper function" do
      expect(output).to include("func csrfToken(w http.ResponseWriter, r *http.Request) string {")
    end

    it "generates CSRFMiddleware struct and constructor" do
      expect(output).to include("type CSRFMiddleware struct{ next http.Handler }")
      expect(output).to include("func NewCSRFMiddleware(next http.Handler) *CSRFMiddleware {")
    end

    it "wraps mux with CSRFMiddleware in ListenAndServe" do
      expect(output).to include("NewCSRFMiddleware(mux)")
    end

    it "does not emit inline validateCSRF function or calls" do
      expect(output).not_to include("func validateCSRF(")
      expect(output).not_to include("if !validateCSRF(w, r)")
    end

    it "passes CsrfToken to index render" do
      expect(output).to include("CsrfToken: csrfToken(w, r)")
    end

    it "includes CsrfToken field in FormData struct" do
      expect(output).to include("CsrfToken string")
    end

    it "imports crypto/rand and encoding/hex for token generation" do
      expect(output).to include('"crypto/rand"')
      expect(output).to include('"encoding/hex"')
    end
  end
end
