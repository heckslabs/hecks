# Hecks::Chapters::Appeal
#
# Self-describing chapter definition for HecksAppeal.
# Enumerates the browser-based IDE aggregates: server, views,
# command dispatcher, and domain bridge.
#
#   domain = Hecks::Chapters::Appeal.definition
#   domain.aggregates.map(&:name)
#   # => ["Server", "CommandDispatcher", "BluebookBridge", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Appeal
      def self.summary = "Browser-based IDE for domain modeling"

      def self.definition
        Hecks::DSL::BluebookBuilder.new("HecksAppeal").tap { |b|
          b.aggregate "Server" do
            description "Sinatra web server hosting the IDE and routing HTTP requests"
            command "Start" do
              attribute :port, Integer
            end
            command "Stop"
          end

          b.aggregate "CommandDispatcher" do
            description "Routes browser form submissions to domain commands via the runtime"
            command "Dispatch" do
              attribute :command_name, String
              attribute :params, Hash
            end
          end

          b.aggregate "BluebookBridge" do
            description "Connects the IDE to a booted Hecks domain for live introspection"
            command "Connect" do
              attribute :domain_path, String
            end
            command "Describe"
          end

          b.aggregate "Views" do
            description "ERB templates rendering domain structure, forms, and event logs"
            command "RenderAggregate" do
              attribute :aggregate_name, String
            end
            command "RenderCommand" do
              attribute :command_name, String
            end
            command "RenderEventLog"
          end

          Chapters.define_paragraphs(Appeal, b)
        }.build
      end
    end
  end
end
