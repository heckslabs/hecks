# Hecks::Chapters::Bluebook
#
# Self-describing domain definition for the Bluebook chapter. The DSL
# and IR layer models itself as a domain: Domain, Aggregate, and Grammar
# are the aggregates; define/validate/generate are the commands.
#
#   domain = Hecks::Chapters::Bluebook.definition
#   domain.aggregates.map(&:name)  # => ["Domain", "Aggregate", "Grammar"]
#
module Hecks
  module Chapters
    module Bluebook
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Bluebook").tap { |b|
          b.instance_eval do
            aggregate "Domain" do
              attribute :name, String
              attribute :version, String

              command "DefineDomain" do
                attribute :name, String
                attribute :version, String
              end

              command "ValidateDomain" do
                attribute :domain_id, String
              end

              command "GenerateCode" do
                attribute :domain_id, String
                attribute :target, String
              end
            end

            aggregate "Aggregate" do
              attribute :name, String
              attribute :domain_name, String

              command "AddAggregate" do
                attribute :name, String
                attribute :domain_name, String
              end

              command "AddAttribute" do
                attribute :aggregate_id, String
                attribute :name, String
                attribute :type, String
              end

              command "AddCommand" do
                attribute :aggregate_id, String
                attribute :name, String
              end

              command "AddPolicy" do
                attribute :aggregate_id, String
                attribute :name, String
                attribute :event_name, String
                attribute :trigger_command, String
              end
            end

            aggregate "Grammar" do
              attribute :name, String

              command "RegisterGrammar" do
                attribute :name, String
              end

              command "ParseInput" do
                attribute :grammar_id, String
                attribute :input, String
              end
            end

            policy "AutoEvent" do
              on "AddedCommand"
              trigger "InferEvent"
            end
          end
        }.build
      end
    end
  end
end
