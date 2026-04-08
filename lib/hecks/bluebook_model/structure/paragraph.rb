# Hecks::BluebookModel::Structure::Paragraph
#
# A named group of aggregates within a chapter (domain). Paragraphs
# organize a chapter's aggregates into focused sections — ports,
# contracts, event sourcing, etc.
#
# In the Bluebook hierarchy: bluebook > binding > chapters > paragraphs
#
#   paragraph = Paragraph.new(name: "Ports", aggregates: [...])
#   paragraph.aggregates.map(&:name)
#   # => ["EventBus", "CommandBus", "Repository"]
#
module Hecks
  module BluebookModel
    module Structure
      class Paragraph
        # @return [String] the paragraph name (e.g., "Ports")
        attr_reader :name

        # @return [Array<Aggregate>] aggregates in this paragraph
        attr_reader :aggregates

        def initialize(name:, aggregates: [])
          @name = name
          @aggregates = aggregates
        end
      end
    end
  end
end
