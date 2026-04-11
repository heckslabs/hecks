# Hecks::Chapters::Appeal::ModelingDiagramsParagraph
#
# Domain paragraph for the modeling chapter of HecksAppeal.
# Defines aggregates for diagram generation, event storming,
# and ubiquitous language glossary.
#
#   Hecks::Chapters::Appeal::ModelingDiagramsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Appeal
      module ModelingDiagramsParagraph
        def self.define(b)
          b.aggregate "Diagram" do
            description "Generated domain visualizations -- aggregate maps, event flows, command graphs."
            attribute :view_type, String
            attribute :nodes, list_of(DiagramNode)
            attribute :edges, list_of(DiagramEdge)

            value_object "DiagramNode" do
              description "An element in the diagram -- aggregate, command, event, or value object"
              attribute :name, String
              attribute :kind, String
              attribute :metadata, String
            end

            value_object "DiagramEdge" do
              description "A relationship between two nodes"
              attribute :from_node, String
              attribute :to_node, String
              attribute :relationship, String
            end

            command "GenerateDiagram" do
              description "Build a diagram for a file. Uses Explorer.last_opened_path when path is not provided."
              attribute :view_type, String
              attribute :path, String
              attribute :domain, String
              emits "DiagramGenerated"
            end

            command "GenerateOverview" do
              description "Build a cross-domain relationship diagram showing all domains and their connections"
              attribute :scope, String
              emits "OverviewGenerated"
            end

            command "SelectView" do
              description "Switch between aggregate map, event flow, or command graph"
              attribute :view_type, String
              emits "ViewSelected"
            end

            command "FilterByAggregate" do
              description "Show only nodes related to a specific aggregate"
              attribute :aggregate_name, String
              emits "DiagramFiltered"
            end

            command "RunAnalysis" do
              description "Analyze domain patterns — coupling, cohesion, naming issues"
              emits "AnalysisCompleted"
            end
          end

          b.aggregate "EventStorm" do
            description "Interactive event storming session. Stickies represent domain concepts."
            attribute :name, String
            attribute :status, String, default: "active"
            attribute :stickies, list_of(Sticky)

            value_object "Sticky" do
              description "A virtual sticky note -- event, command, policy, hotspot, or external system"
              attribute :label, String
              attribute :kind, String
              attribute :color, String
              attribute :position_x, Integer
              attribute :position_y, Integer
              attribute :notes, String
            end

            command "StartStorm" do
              description "Begin a new event storming session"
              attribute :name, String
            end

            command "AddSticky" do
              description "Place a new sticky note on the board"
              attribute :label, String
              attribute :kind, String
            end

            command "MoveSticky" do
              description "Reposition a sticky on the board"
              attribute :label, String
              attribute :position_x, Integer
              attribute :position_y, Integer
            end

            command "ConvertToDomain" do
              description "Transform stickies into Bluebook DSL aggregates, commands, and events"
              end

            validation :name, presence: true
          end

          b.aggregate "Glossary" do
            description "Ubiquitous language dictionary. Defines terms, enforces naming consistency."
            attribute :terms, list_of(Term)

            value_object "Term" do
              description "A domain term with its definition and category"
              attribute :name, String
              attribute :definition, String
              attribute :category, String
              attribute :aliases, String
            end

            command "ShowGlossary" do
              description "Display the full glossary of domain terms"
              emits "GlossaryShown"
            end

            command "DefineTerm" do
              description "Add a new term to the glossary"
              attribute :name, String
              attribute :definition, String
              attribute :category, String
            end

            command "RenameTerm" do
              description "Rename a term and update all references"
              attribute :old_name, String
              attribute :new_name, String
            end

            command "FlagAmbiguity" do
              description "Mark a term as ambiguous -- needs clarification"
              attribute :term_name, String
              attribute :reason, String
            end

            command "LinkTerms" do
              description "Declare a relationship between two terms"
              attribute :from_term, String
              attribute :to_term, String
              attribute :relationship, String
            end
          end
        end
      end
    end
  end
end
