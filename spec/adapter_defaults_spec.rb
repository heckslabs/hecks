require "spec_helper"

# A field's `default:` in a `.adapter` file, and where the framework lays it under a world's
# settings.
RSpec.describe "adapter field defaults" do
  let(:registry)  { Hecks::Runtime::Registry.new }
  let(:aggregate) { Struct.new(:name, :storage_name).new("OrderLine", "order_line") }

  def root = File.expand_path("..", __dir__)

  # Declares an adapter "Pilot" on the persistence port with the given fields, each
  # `name => options`.
  def declare(**fields)
    Hecks.with_registry(registry) do
      Kernel.load(File.join(root, "lib/hecks/ports/persistence.port"))
      Hecks.adapter("Pilot") do
        port "persistence"
        fields.each { |name, options| field(name, **options) }
      end
    end
  end

  def load_adapter(file)
    Hecks.with_registry(registry) do
      Kernel.load(File.join(root, "lib/hecks/ports/persistence.port"))
      Kernel.load(File.join(root, "lib/hecks/adapters/driven", file))
    end
  end

  def settings_for(adapter, given = {}) = registry.with_adapter_defaults(adapter, aggregate, given)

  describe "the .adapter language" do
    it "keeps the default a field declares" do
      adapter = declare(dir: { default: "data" })

      expect(adapter.declared_defaults).to eq(dir: "data")
    end

    it "declares no default for a field that gives none" do
      adapter = declare(dir: {})

      expect(adapter.declared_defaults).to eq({})
    end

    it "treats false as a default, not as none" do
      adapter = declare(strict: { default: false })

      expect(adapter.declared_defaults).to eq(strict: false)
    end

    it "refuses a placeholder the framework does not fill" do
      expect { declare(dir: { default: "{wat}/x" }) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /AdapterFieldDefault/)
    end
  end

  describe "laying defaults under a world's settings" do
    before { declare(dir: { default: "data" }, database: { default: "data/{storage_name}.db" }) }

    it "fills {storage_name} from the aggregate" do
      expect(settings_for("Pilot")[:database]).to eq("data/order_line.db")
    end

    it "keeps a setting the world gives" do
      expect(settings_for("Pilot", dir: "custom")[:dir]).to eq("custom")
    end

    it "treats a field the world gives as :default as asking for the declared default" do
      expect(settings_for("Pilot", dir: :default)[:dir]).to eq("data")
    end

    it "leaves an adapter that declares nothing with only what the world gave" do
      expect(settings_for("Unknown", dir: "x")).to eq(dir: "x")
    end
  end

  describe "fills {name} from the aggregate" do
    it "puts the aggregate's own name where the placeholder stands" do
      declare(prefix: { default: "{name}-" })

      expect(settings_for("Pilot")[:prefix]).to eq("OrderLine-")
    end
  end

  describe "the persistence adapters that ship" do
    it "gives Heki a data directory" do
      load_adapter("heki.adapter")

      expect(settings_for("Heki")).to eq(dir: "data")
    end

    it "gives Lambda the us-east-1 region" do
      load_adapter("lambda.adapter")

      expect(settings_for("Lambda")).to eq(region: "us-east-1")
    end

    it "gives Sqlite a database file named for the aggregate" do
      load_adapter("sqlite.adapter")

      expect(settings_for("SqlitePersistence")).to eq(database: "data/order_line.db")
    end
  end
end
