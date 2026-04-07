# Hecks::Chapters::Workshop::RunnersParagraph
#
# Paragraph covering workshop runners: IRB runner, web runner,
# command parser, evaluator, state serializer, and IDE session.
#
#   Hecks::Chapters::Workshop::RunnersParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module RunnersParagraph
        def self.define(b)
          b.aggregate "WorkshopRunner" do
            description "Interactive IRB workshop that hoists constants for direct REPL use"
            command "Run"
          end

          b.aggregate "ConstantHoister" do
            description "Manages hoisting and cleanup of constants on WorkshopRunner"
            command "HoistAggregate" do
              attribute :const_name, String
            end
          end

          b.aggregate "WebRunner" do
            description "Browser-based REPL with WEBrick server for the Workshop"
            command "Run"
          end

          b.aggregate "Evaluator" do
            description "Safe eval-free command execution delegating to CommandParser"
            command "Evaluate" do
              attribute :input, String
            end
          end

          b.aggregate "CommandParser" do
            description "Safe command dispatcher using BlueBook Grammar for the web workshop"
            command "Execute" do
              attribute :input, String
            end
          end

          b.aggregate "StateSerializer" do
            description "Serializes workshop state into JSON for the browser console"
            command "Serialize"
          end

          b.aggregate "WorkshopSession" do
            description "Wraps Workshop WebRunner for IDE integration with safe command eval"
            command "Execute" do
              attribute :input, String
            end
            command "GetCompletions"
          end
        end
      end
    end
  end
end
