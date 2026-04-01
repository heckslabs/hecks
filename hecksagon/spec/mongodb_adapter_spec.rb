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

  let(:vo_domain) do
    Hecks.domain "Recipes" do
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
  end

  let(:single_vo_domain) do
    Hecks.domain "Addresses" do
      aggregate "User" do
        attribute :name, String
        attribute :address, "Address"

        value_object "Address" do
          attribute :street, String
          attribute :city, String
        end

        command "CreateUser" do
          attribute :name, String
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

  it "includes the port module" do
    Hecks.load(domain)
    agg = domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "PizzasDomain")
    source = gen.generate

    expect(source).to include("include Ports::PizzaRepository")
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

  it "serializes list VOs as arrays of hashes" do
    Hecks.load(vo_domain)
    agg = vo_domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "RecipesDomain")
    source = gen.generate

    expect(source).to include('"ingredients" => (obj.ingredients || []).map')
    expect(source).to include('"name" => item.name')
    expect(source).to include('"grams" => item.grams')
  end

  it "deserializes list VOs from arrays of hashes" do
    Hecks.load(vo_domain)
    agg = vo_domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "RecipesDomain")
    source = gen.generate

    expect(source).to include('Recipe::Ingredient.new(')
    expect(source).to include('name: h["name"]')
    expect(source).to include('grams: h["grams"]')
  end

  it "serializes single VOs as nested hashes" do
    Hecks.load(single_vo_domain)
    agg = single_vo_domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "AddressesDomain")
    source = gen.generate

    expect(source).to include('"address" =>')
    expect(source).to include('obj.address ? {')
    expect(source).to include('"street" => obj.address&.street')
    expect(source).to include('"city" => obj.address&.city')
  end

  it "deserializes single VOs from nested hashes" do
    Hecks.load(single_vo_domain)
    agg = single_vo_domain.aggregates.first
    gen = Hecks::MongoAdapterGenerator.new(agg, domain_module: "AddressesDomain")
    source = gen.generate

    expect(source).to include('User::Address.new(')
    expect(source).to include('street: h["street"]')
    expect(source).to include('city: h["city"]')
  end
end
