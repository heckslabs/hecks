require "hecks"

RSpec.describe "HEC-70: Event Versioning & Upcasting" do
  let(:registry) { Hecks::EventSourcing::UpcasterRegistry.new }
  let(:engine) { Hecks::EventSourcing::UpcasterEngine.new(registry) }

  describe "UpcasterRegistry" do
    it "registers and retrieves upcasters" do
      registry.register("CreatedPizza", from: 1, to: 2) { |d| d.merge("size" => "medium") }
      expect(registry.upcasters_for("CreatedPizza").size).to eq(1)
      expect(registry.any?("CreatedPizza")).to be true
      expect(registry.any?("UnknownEvent")).to be false
    end

    it "sorts upcasters by from_version" do
      registry.register("X", from: 3, to: 4) { |d| d }
      registry.register("X", from: 1, to: 2) { |d| d }
      versions = registry.upcasters_for("X").map(&:from_version)
      expect(versions).to eq([1, 3])
    end
  end

  describe "UpcasterEngine" do
    it "upcasts through a single version" do
      registry.register("CreatedPizza", from: 1, to: 2) do |data|
        data.merge("size" => "medium")
      end

      result = engine.upcast("CreatedPizza", { "name" => "Margherita" }, from_version: 1)
      expect(result).to eq({ "name" => "Margherita", "size" => "medium" })
    end

    it "chains multiple upcasts" do
      registry.register("CreatedPizza", from: 1, to: 2) do |data|
        data.merge("size" => "medium")
      end
      registry.register("CreatedPizza", from: 2, to: 3) do |data|
        data.merge("crust" => "thin")
      end

      result = engine.upcast("CreatedPizza", { "name" => "M" }, from_version: 1)
      expect(result).to eq({ "name" => "M", "size" => "medium", "crust" => "thin" })
    end

    it "returns data unchanged when no upcasters match" do
      data = { "name" => "M" }
      result = engine.upcast("UnknownEvent", data, from_version: 1)
      expect(result).to eq(data)
    end

    it "skips upcasters below the from_version" do
      registry.register("X", from: 1, to: 2) { |d| d.merge("v2" => true) }
      registry.register("X", from: 2, to: 3) { |d| d.merge("v3" => true) }

      result = engine.upcast("X", { "base" => true }, from_version: 2)
      expect(result).to eq({ "base" => true, "v3" => true })
    end
  end
end
