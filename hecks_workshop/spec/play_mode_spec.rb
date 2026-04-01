require "spec_helper"

RSpec.describe "Play mode" do
  def build_workshop
    wb = Hecks::Workshop.new("Scratch")
    pizza = wb.aggregate("Pizza")
    pizza.attr :name, String
    pizza.attr :style, String
    pizza.command("CreatePizza") { attribute :name, String; attribute :style, String }
    pizza.command("RenamePizza") { attribute :name, String }
    cat = wb.aggregate("Cat")
    cat.attr :name, String
    cat.command("Meow") { attribute :name, String }
    wb
  end

  before { allow($stdout).to receive(:puts) }

  describe "entering play mode" do
    it "compiles and enters play mode" do
      wb = build_workshop
      wb.play!
      expect(wb.play?).to be true
    end

    it "makes aggregate classes available" do
      wb = build_workshop
      wb.play!
      mod = Object.const_get("ScratchDomain")
      expect(mod.const_defined?(:Pizza)).to be true
      expect(mod.const_defined?(:Cat)).to be true
    end

    it "can create aggregate instances" do
      wb = build_workshop
      wb.play!
      mod = Object.const_get("ScratchDomain")
      pizza = mod::Pizza.new(name: "Margherita")
      expect(pizza.name).to eq("Margherita")
    end
  end

  context "with compiled domain" do
    before(:all) do
      $stdout = File.open(File::NULL, "w")
      @wb = Hecks::Workshop.new("Scratch")
      pizza = @wb.aggregate("Pizza")
      pizza.attr :name, String
      pizza.attr :style, String
      pizza.command("CreatePizza") { attribute :name, String; attribute :style, String }
      pizza.command("RenamePizza") { attribute :name, String }
      cat = @wb.aggregate("Cat")
      cat.attr :name, String
      cat.command("Meow") { attribute :name, String }
      @wb.play!
      @mod = Object.const_get("ScratchDomain")
      $stdout = STDOUT
    end

    describe "execute" do
      it "executes a command by name" do
        pizza = @mod::Pizza.create(name: "Pepperoni", style: "NY")
        expect(pizza.name).to eq("Pepperoni")
      end

      it "collects events" do
        @mod::Pizza.create(name: "Margherita", style: "Neapolitan")
        @mod::Cat.meow(name: "Henry")
        expect(@wb.events.size).to be >= 2
      end
    end

    describe "command shortcut class methods" do
      it "defines class methods on aggregates" do
        expect(@mod::Pizza).to respond_to(:create)
        expect(@mod::Cat).to respond_to(:meow)
      end

      it "executes via class method" do
        event = @mod::Pizza.create(name: "Pepperoni", style: "NY")
        expect(event.name).to eq("Pepperoni")
      end

      it "strips aggregate suffix from method name" do
        expect(@mod::Pizza).to respond_to(:create)
        expect(@mod::Pizza).to respond_to(:rename)
      end
    end

    describe "command shortcut instance methods" do
      it "defines instance methods on aggregates" do
        cat = @mod::Cat.new(name: "Henry")
        expect(cat).to respond_to(:meow)
      end

      it "auto-fills from instance attributes" do
        cat = @mod::Cat.new(name: "Henry")
        event = cat.meow
        expect(event.name).to eq("Henry")
      end

      it "accepts keyword overrides" do
        cat = @mod::Cat.new(name: "Henry")
        event = cat.meow(name: "Whiskers")
        expect(event.name).to eq("Whiskers")
      end

      it "works with multiple attributes" do
        pizza = @mod::Pizza.new(name: "Margherita", style: "Neapolitan")
        event = pizza.create
        expect(event.name).to eq("Margherita")
      end

      it "allows partial overrides" do
        pizza = @mod::Pizza.new(name: "Margherita", style: "Neapolitan")
        event = pizza.create(name: "Pepperoni")
        expect(event.name).to eq("Pepperoni")
      end
    end

    describe "reset!" do
      it "restores attributes to constructor values" do
        cat = @mod::Cat.new(name: "Henry")
        cat.name = "Whiskers"
        cat.reset!
        expect(cat.name).to eq("Henry")
      end

      it "preserves identity" do
        cat = @mod::Cat.new(name: "Henry")
        id = cat.id
        cat.name = "Whiskers"
        cat.reset!
        expect(cat.id).to eq(id)
      end

      it "returns self for chaining" do
        cat = @mod::Cat.new(name: "Henry")
        cat.name = "Whiskers"
        expect(cat.reset!).to equal(cat)
      end
    end

    describe "events and history" do
      it "events_of filters by type" do
        @mod::Pizza.create(name: "A", style: "NY")
        @mod::Cat.meow(name: "Henry")
        @mod::Pizza.create(name: "B", style: "Chicago")
        created = @wb.events_of("CreatedPizza")
        expect(created.size).to be >= 2
      end

      it "history prints timeline" do
        @mod::Pizza.create(name: "Margherita", style: "NY")
        expect { @wb.history }.to output(/CreatedPizza/).to_stdout
      end
    end

    describe "aggregate inspect" do
      it "shows a concise representation with attributes" do
        pizza = @mod::Pizza.create(name: "Margherita", style: "NY")
        output = pizza.inspect
        expect(output).to include("Pizza")
        expect(output).to include("name: \"Margherita\"")
        expect(output).to include("style: \"NY\"")
        expect(output).to match(/id:\w{8}/)
      end
    end

    describe "last_event" do
      it "returns the most recent event" do
        @mod::Pizza.create(name: "Test", style: "NY")
        event = @wb.last_event
        expect(Hecks::Utils.const_short_name(event)).to eq("CreatedPizza")
      end

      it "returns nil when no events" do
        fresh_wb = Hecks::Workshop.new("Fresh")
        expect(fresh_wb.last_event).to be_nil
      end
    end

    describe "persistence" do
      it "persists aggregates after execute" do
        result = @mod::Pizza.create(name: "Margherita", style: "NY")
        found = @mod::Pizza.find(result.id)
        expect(found.name).to eq("Margherita")
      end

      it "supports all" do
        @mod::Pizza.create(name: "A", style: "NY")
        @mod::Pizza.create(name: "B", style: "Chicago")
        expect(@mod::Pizza.all.size).to be >= 2
      end

      it "supports count" do
        @mod::Cat.meow(name: "Henry")
        expect(@mod::Cat.count).to be >= 1
      end

      it "persists via class method shortcuts" do
        pizza = @mod::Pizza.create(name: "Pepperoni", style: "NY")
        expect(@mod::Pizza.find(pizza.id).name).to eq("Pepperoni")
      end
    end
  end

  describe "sketch! / play! toggling" do
    it "can switch back to sketch mode" do
      wb = build_workshop
      wb.play!
      wb.sketch!
      expect(wb.play?).to be false
    end

    it "can re-enter play mode after changes" do
      wb = build_workshop
      cat = wb.aggregate("Cat")
      cat.command("Purr") { attribute :name, String }
      wb.play!
      mod = Object.const_get("ScratchDomain")
      event = mod::Cat.new(name: "Henry").purr
      expect(event.name).to eq("Henry")
    end
  end

  describe "live extend" do
    it "applies logging extension to running runtime" do
      wb = build_workshop
      wb.play!
      wb.extend(:logging)
      mod = Object.const_get("ScratchDomain")
      expect { mod::Pizza.create(name: "Test", style: "NY") }.to output(/CreatePizza/).to_stdout
    end

    it "raises for unknown extension" do
      wb = build_workshop
      wb.play!
      expect { wb.extend(:nonexistent) }.to raise_error(RuntimeError, /Unknown extension/)
    end

    it "requires play mode" do
      wb = build_workshop
      expect { wb.extend(:logging) }.to raise_error(RuntimeError, /Not in play mode/)
    end
  end
end
