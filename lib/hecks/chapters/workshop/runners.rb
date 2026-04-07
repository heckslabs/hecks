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

          b.aggregate "WebRunner" do
            description "Browser-based REPL with WEBrick server for the Workshop"
            command "Run"
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
