# Hecks::Chapters::Bluebook::NamesParagraph
#
# Paragraph covering the naming layer: type-safe name objects that
# provide inflection and formatting for aggregates, commands, events,
# and states throughout the compiler pipeline.
#
#   Hecks::Chapters::Bluebook::NamesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module NamesParagraph
        def self.define(b)
          b.aggregate "BaseName", "Root name object with inflection and formatting methods" do
            command("CreateName") { attribute :raw, String }
          end

          b.aggregate "AggregateName", "Name specialization for aggregates (singular, plural, module)" do
            command("CreateAggregateName") { attribute :raw, String }
          end

          b.aggregate "CommandName", "Name specialization for commands (past tense, event form)" do
            command("CreateCommandName") { attribute :raw, String }
          end

          b.aggregate "EventName", "Name specialization for domain events (past participle)" do
            command("CreateEventName") { attribute :raw, String }
          end

          b.aggregate "StateName", "Name specialization for lifecycle states (snake, label)" do
            command("CreateStateName") { attribute :raw, String }
          end
        end
      end
    end
  end
end
