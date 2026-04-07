# Hecks::Chapters::Kernel::DomainModelParagraph
#
# Paragraph describing the domain model intermediate representation.
# Covers Structure (data shapes), Behavior (commands, events, policies),
# Names (typed identifiers), and the Tokenizer (DSL argument parsing).
#
#   Hecks::Chapters::Kernel::DomainModelParagraph.define(builder)
#
module Hecks
  module Chapters
    module Kernel
      module DomainModelParagraph
        def self.define(b)
          b.aggregate "StructureModule", "Namespace for structural IR nodes: domains, aggregates, value objects, attributes, references" do
            command("DefineStructure") { attribute :domain_id, String }
          end

          b.aggregate "BehaviorModule", "Namespace for behavior IR nodes: commands, events, policies, queries, workflows, services" do
            command("DefineBehavior") { attribute :domain_id, String }
          end

          b.aggregate "NamesModule", "Value objects for typed domain identifiers: CommandName, EventName, AggregateName, StateName" do
            command("CreateName") { attribute :value, String; attribute :kind, String }
          end

          b.aggregate "Tokenizer", "Splits DSL command argument strings into typed tokens for parsing" do
            attribute :input, String
            command("TokenizeInput") { attribute :input, String }
          end
        end
      end
    end
  end
end
