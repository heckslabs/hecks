# Hecks::Chapters::Workshop::TourStepsParagraph
#
# Paragraph covering Tour children: sketch steps and play steps.
#
#   Hecks::Chapters::Workshop::TourStepsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Workshop
      module TourStepsParagraph
        def self.define(b)
          b.aggregate "SketchSteps" do
            description "Tour step definitions for the sketch phase: aggregates, attributes, lifecycle, transitions"
            command "CreateAggregateStep"
            command "AddAttributeStep"
            command "AddLifecycleStep"
            command "BrowseStep"
            command "ValidateStep"
          end

          b.aggregate "PlaySteps" do
            description "Tour step definitions for the play phase: entering play, executing commands, building"
            command "EnterPlayStep"
            command "CreateInstanceStep"
            command "QueryAllStep"
            command "CheckEventsStep"
            command "BuildStep"
          end
        end
      end
    end
  end
end
