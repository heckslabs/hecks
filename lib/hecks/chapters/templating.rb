# Hecks::Chapters::Templating
#
# Self-describing chapter for the HecksTemplating component. Covers
# naming convention helpers and browser-style HTTP smoke testing.
#
#   domain = Hecks::Chapters::Templating.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    # Hecks::Chapters::Templating
    #
    # Bluebook chapter defining the HecksTemplating component: naming helpers and HTTP smoke testing.
    #
    module Templating
      def self.definition
        DSL::DomainBuilder.new("Templating").tap { |b|
          b.aggregate "NamingHelpers" do
            description "Mixin providing domain naming convention methods for modules, gems, slugs, and routes"
            command "DomainModuleName" do
              attribute :name, String
            end
            command "DomainGemName" do
              attribute :name, String
            end
            command "DomainAggregateSlug" do
              attribute :name, String
            end
            command "DomainCommandMethod" do
              attribute :command_name, String
              attribute :aggregate_name, String
            end
            command "DomainRoutePath" do
              attribute :domain_name, String
              attribute :aggregate_name, String
            end
          end

          b.aggregate "SmokeTest" do
            description "Browser-style HTTP smoke test that exercises every page like a real user"
            command "Run" do
              attribute :base_url, String
              attribute :domain_name, String
            end
          end

          Chapters.define_paragraphs(Templating, b)
        }.build
      end
    end
  end
end
