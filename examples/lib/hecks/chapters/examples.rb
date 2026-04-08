# Hecks::Chapters::Examples
#
# Self-describing chapter for the Hecks example applications. Each
# example demonstrates a different aspect of the framework: basic
# domain modeling, event sourcing, SQL persistence, multi-domain
# composition, static code generation, and web frameworks.
#
#   domain = Hecks::Chapters::Examples.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    module Examples
      def self.definition
        DSL::BluebookBuilder.new("Examples").tap { |b|
          b.aggregate "PizzasApp" do
            description "Canonical example: pizza domain with CRUD, events, queries, and lifecycle"
            command "Run"
          end

          b.aggregate "BankingApp" do
            description "Multi-aggregate example: accounts, customers, loans, transfers with policies"
            command "Run"
          end

          b.aggregate "BookshelfApp" do
            description "Simple domain example: books with authors and categories"
            command "Run"
          end

          b.aggregate "GovernanceApp" do
            description "World concerns example: consent, privacy, security, transparency"
            command "Run"
          end

          b.aggregate "MultiDomainApp" do
            description "Cross-domain composition: multiple domains with shared event bus"
            command "Run"
          end

          b.aggregate "PizzasStaticRuby" do
            description "Static Ruby target: pre-generated domain gem from pizzas Bluebook"
            command "Generate"
          end

          b.aggregate "PizzasStaticGo" do
            description "Static Go target: pre-generated Go structs from pizzas Bluebook"
            command "Generate"
          end

          b.aggregate "GovernanceStaticGo" do
            description "Static Go target for governance domain with world concerns"
            command "Generate"
          end

          b.aggregate "PizzasRails" do
            description "Rails integration example: Hecks.configure with Rails app"
            command "Run"
          end

          b.aggregate "RailsApp" do
            description "Full Rails app skeleton with Hecks domain wired in"
            command "Run"
          end

          b.aggregate "SinatraApp" do
            description "Sinatra integration example: lightweight web app with Hecks domain"
            command "Run"
          end

          b.aggregate "SpaghettiWestern" do
            description "Refactoring example: transforming procedural code into a Hecks domain"
            command "Run"
          end

          b.aggregate "EventStorm" do
            description "Event storm import example: YAML event storm to Bluebook domain"
            command "Import" do
              attribute :yaml_path, String
            end
          end

          b.aggregate "BluebookChapters" do
            description "Self-hosting example: chapter definitions describing Hecks itself"
            command "ListChapters"
          end
        }.build
      end
    end
  end
end
