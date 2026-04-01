require "spec_helper"
require "hecks_mongodb/mongo_adapter_generator"

RSpec.describe "MongoDB adapter generator" do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String
        attribute :style, String

        command "CreatePizza" do
          attribute :name, String
          attribute :style, String
        end
      end
    end
  end

  after { Hecks::Utils.cleanup_constants! }

  it "generates a MongoRepository class" do
    Hecks.load(domain)
    agg = domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "PizzasDomain")
    source = gen.generate

    expect(source).to include("class PizzaMongoRepository")
    expect(source).to include("def find(id)")
    expect(source).to include("def save(pizza)")
    expect(source).to include("def delete(id)")
    expect(source).to include("def all")
    expect(source).to include("def count")
    expect(source).to include("def query(")
    expect(source).to include("def clear")
    expect(source).to include("def serialize(obj)")
    expect(source).to include("def deserialize(doc)")
  end

  it "includes all aggregate attributes in serialize" do
    Hecks.load(domain)
    agg = domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "PizzasDomain")
    source = gen.generate

    expect(source).to include('"name" => obj.name')
    expect(source).to include('"style" => obj.style')
    expect(source).to include('"_id" => obj.id')
  end

  it "deserializes with keyword args from doc" do
    Hecks.load(domain)
    agg = domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "PizzasDomain")
    source = gen.generate

    expect(source).to include('name: doc["name"]')
    expect(source).to include('style: doc["style"]')
  end
end
