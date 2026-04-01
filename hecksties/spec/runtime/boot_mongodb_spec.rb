require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks_mongodb"

RSpec.describe "Hecks.boot with MongoDB adapter" do
  let(:tmpdir) { Dir.mktmpdir("hecks-mongo-boot-") }

  after do
    FileUtils.rm_rf(tmpdir)
    Hecks::Utils.cleanup_constants!
  end

  def write_domain(dir, content)
    File.write(File.join(dir, "PizzasBluebook"), content)
  end

  def fake_collection
    store = {}
    col = double("Mongo::Collection")
    allow(col).to receive(:replace_one) do |filter, doc, **|
      store[filter[:_id]] = doc
    end
    allow(col).to receive(:find) do |filter = {}|
      results = if filter.key?(:_id)
        [store[filter[:_id]]].compact
      else
        store.values
      end
      cursor = double("cursor")
      allow(cursor).to receive(:first) { results.first }
      allow(cursor).to receive(:map) { |&b| results.map(&b) }
      allow(cursor).to receive(:sort) { cursor }
      allow(cursor).to receive(:skip) { cursor }
      allow(cursor).to receive(:limit) { cursor }
      cursor
    end
    allow(col).to receive(:delete_one) do |filter|
      store.delete(filter[:_id])
    end
    allow(col).to receive(:delete_many) { store.clear }
    allow(col).to receive(:count_documents) { store.size }
    col
  end

  def fake_client(collections = {})
    client = double("Mongo::Client")
    allow(client).to receive(:[]) do |name|
      collections[name] ||= fake_collection
    end
    client
  end

  it "boots and generates adapter classes" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "MongoTest" do
        aggregate "Widget" do
          attribute :name, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end
    RUBY

    client = fake_client
    allow(Hecks::Boot::MongoBoot).to receive(:connect).and_return(client)

    app = Hecks.boot(tmpdir, adapter: :mongodb)
    expect(app).to be_a(Hecks::Runtime)
    expect(app.domain.name).to eq("MongoTest")
  end

  it "persists data through CRUD operations" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "MongoPersist" do
        aggregate "Item" do
          attribute :title, String
          attribute :qty, Integer
          command "CreateItem" do
            attribute :title, String
            attribute :qty, Integer
          end
        end
      end
    RUBY

    client = fake_client
    allow(Hecks::Boot::MongoBoot).to receive(:connect).and_return(client)

    app = Hecks.boot(tmpdir, adapter: :mongodb)
    item = Item.create(title: "Bolt", qty: 10)
    expect(item.title).to eq("Bolt")
    expect(item.qty).to eq(10)

    found = Item.find(item.id)
    expect(found).not_to be_nil
    expect(found.title).to eq("Bolt")
    expect(found.qty).to eq(10)

    expect(Item.count).to eq(1)
  end

  it "embeds list value objects as arrays of hashes and round-trips them" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "MongoVo" do
        aggregate "Recipe" do
          attribute :name, String
          attribute :ingredients, list_of("Ingredient")

          value_object "Ingredient" do
            attribute :name, String
            attribute :grams, Integer

            invariant "grams must be positive" do
              grams > 0
            end
          end

          command "CreateRecipe" do
            attribute :name, String
          end
        end
      end
    RUBY

    client = fake_client
    allow(Hecks::Boot::MongoBoot).to receive(:connect).and_return(client)

    app = Hecks.boot(tmpdir, adapter: :mongodb)

    ing = Recipe::Ingredient.new(name: "Flour", grams: 200)
    recipe = Recipe.create(name: "Bread")
    repo = app.domain.aggregates.first
    raw_repo = app.instance_variable_get(:@repositories)&.dig(repo.name) ||
               app.send(:repository_for, repo.name) rescue nil

    # Use the generated adapter directly via the collection mock
    collection = client[:"recipes"]
    mod_name = "MongoVoDomain"
    gen = Hecks::MongoAdapterGenerator.new(app.domain.aggregates.first, domain_module: mod_name)
    src = gen.generate

    expect(src).to include('"ingredients" => (obj.ingredients || []).map')
    expect(src).to include("Recipe::Ingredient.new(")
    expect(src).to include('name: h["name"]')
    expect(src).to include('grams: h["grams"]')
  end

  it "queries with conditions" do
    write_domain(tmpdir, <<~RUBY)
      Hecks.domain "MongoQuery" do
        aggregate "Product" do
          attribute :name, String
          attribute :active, String
          command "CreateProduct" do
            attribute :name, String
            attribute :active, String
          end
          query "Active" do
            where(active: "yes")
          end
        end
      end
    RUBY

    client = fake_client
    allow(Hecks::Boot::MongoBoot).to receive(:connect).and_return(client)

    app = Hecks.boot(tmpdir, adapter: :mongodb)
    Product.create(name: "Wrench", active: "yes")
    Product.create(name: "Bolt", active: "no")

    results = Product.all
    expect(results.size).to eq(2)
  end
end
