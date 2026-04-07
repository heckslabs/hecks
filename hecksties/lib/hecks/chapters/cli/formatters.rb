# = Hecks::Chapters::Cli::CliFormatters
#
# Self-describing sub-chapter for domain inspector formatters. Each
# formatter renders a section of the aggregate IR for terminal display.
#
#   Hecks::Chapters::Cli::CliFormatters.define(builder)
#
module Hecks
  module Chapters
    module Cli
      # Hecks::Chapters::Cli::CliFormatters
      #
      # Bluebook sub-chapter defining domain inspector formatters for terminal display.
      #
      module CliFormatters
        def self.define(b)
          b.aggregate "AggregateFormatter", "Formats a single aggregate IR into readable terminal output" do
            command("Format") { attribute :aggregate, String }
          end

          b.aggregate "BehaviorFormatters", "Formats commands, events, and queries for display" do
            command("Format") { attribute :aggregate, String }
          end

          b.aggregate "StructureFormatters", "Formats attributes, value objects, and entities for display" do
            command("Format") { attribute :aggregate, String }
          end

          b.aggregate "LifecycleFormatter", "Formats lifecycle states and transitions for display" do
            command("Format") { attribute :aggregate, String }
          end

          b.aggregate "RuleFormatters", "Formats validations, invariants, and policies for display" do
            command("Format") { attribute :aggregate, String }
          end

          b.aggregate "SecondaryFormatters", "Formats scopes, specifications, subscribers, references, computed attributes" do
            command("Format") { attribute :aggregate, String }
          end
        end
      end
    end
  end
end
