require "spec_helper"
require "node_hecks"

RSpec.describe NodeHecks::NodeGenerator do
  let(:domain) do
    Hecks.domain("Pizzas") do
      aggregate("Pizza") do
        attribute :name, String
        attribute :description, String
        attribute :price, Float
        attribute :vegetarian, :boolean
        command("CreatePizza") { attribute :name, String; attribute :description, String }
        command("UpdatePizza") { attribute :pizza_id, String; attribute :name, String }
      end
    end
  end

  describe NodeHecks::AggregateGenerator do
    let(:agg) { domain.aggregates.first }
    let(:output) { described_class.new(agg).generate }

    it "generates a TypeScript interface with the aggregate name" do
      expect(output).to include("export interface Pizza {")
    end

    it "includes id, createdAt, and updatedAt fields" do
      expect(output).to include("id: string;")
      expect(output).to include("createdAt: string;")
      expect(output).to include("updatedAt: string;")
    end

    it "maps String attributes to string type" do
      expect(output).to include("name: string;")
    end

    it "maps Float attributes to number type" do
      expect(output).to include("price: number;")
    end

    it "maps Boolean attributes to boolean type" do
      expect(output).to include("vegetarian: boolean;")
    end
  end

  describe NodeHecks::CommandGenerator do
    let(:agg) { domain.aggregates.first }
    let(:create_cmd) { agg.commands[0] }
    let(:create_event) { agg.events[0] }
    let(:output) { described_class.new(create_cmd, aggregate: agg, event: create_event).generate }

    it "generates an attrs interface" do
      expect(output).to include("export interface CreatePizzaAttrs {")
    end

    it "generates an event interface with type field" do
      expect(output).to include("export interface CreatedPizza {")
      expect(output).to include('type: "CreatedPizza";')
    end

    it "generates a command function" do
      expect(output).to include("export function createPizza(")
    end

    it "imports the aggregate type" do
      expect(output).to include('import { Pizza } from "../aggregates/pizza";')
    end

    it "imports the repository" do
      expect(output).to include('import { PizzaRepository } from "../repositories/pizza_repository";')
    end

    context "with an update command (self-referencing ID)" do
      let(:update_cmd) { agg.commands[1] }
      let(:update_event) { agg.events[1] }
      let(:output) { described_class.new(update_cmd, aggregate: agg, event: update_event).generate }

      it "generates a function that finds existing entity" do
        expect(output).to include("repo.find(attrs.pizzaId)")
      end

      it "throws on not found" do
        expect(output).to include('throw new Error("Pizza not found")')
      end
    end
  end

  describe NodeHecks::RepositoryGenerator do
    let(:agg) { domain.aggregates.first }
    let(:output) { described_class.new(agg).generate }

    it "generates a repository class" do
      expect(output).to include("export class PizzaRepository {")
    end

    it "uses Map for storage" do
      expect(output).to include("private store: Map<string, Pizza>")
    end

    it "generates all(), find(), save(), delete() methods" do
      expect(output).to include("all(): Pizza[]")
      expect(output).to include("find(id: string): Pizza | undefined")
      expect(output).to include("save(entity: Pizza): void")
      expect(output).to include("delete(id: string): void")
    end

    it "imports the aggregate type" do
      expect(output).to include('import { Pizza } from "../aggregates/pizza";')
    end
  end

  describe NodeHecks::ServerGenerator do
    let(:output) { described_class.new(domain).generate }

    it "imports express" do
      expect(output).to include('import express from "express"')
    end

    it "generates GET list route" do
      expect(output).to include('app.get("/pizzas"')
    end

    it "generates GET by id route" do
      expect(output).to include('app.get("/pizzas/:id"')
    end

    it "generates POST route for each command" do
      expect(output).to include('app.post("/pizzas/create_pizza"')
      expect(output).to include('app.post("/pizzas/update_pizza"')
    end

    it "listens on configurable port" do
      expect(output).to include("app.listen(port")
    end

    it "instantiates repositories" do
      expect(output).to include("new PizzaRepository()")
    end
  end

  describe NodeHecks::ProjectGenerator do
    let(:dir) { Dir.mktmpdir }
    let(:output_path) { described_class.new(domain, output_dir: dir).generate }

    after { FileUtils.rm_rf(dir) }

    it "creates the project directory" do
      expect(Dir.exist?(output_path)).to be true
    end

    it "generates package.json" do
      expect(File.exist?(File.join(output_path, "package.json"))).to be true
    end

    it "generates tsconfig.json with strict mode" do
      tsconfig = File.read(File.join(output_path, "tsconfig.json"))
      expect(tsconfig).to include('"strict": true')
      expect(tsconfig).to include('"module": "ESNext"')
    end

    it "generates aggregate TypeScript files" do
      expect(File.exist?(File.join(output_path, "src/aggregates/pizza.ts"))).to be true
    end

    it "generates command TypeScript files" do
      expect(File.exist?(File.join(output_path, "src/commands/create_pizza.ts"))).to be true
    end

    it "generates repository TypeScript files" do
      expect(File.exist?(File.join(output_path, "src/repositories/pizza_repository.ts"))).to be true
    end

    it "generates server.ts" do
      expect(File.exist?(File.join(output_path, "src/server.ts"))).to be true
    end

    it "generates README.md" do
      expect(File.exist?(File.join(output_path, "README.md"))).to be true
    end
  end
end
