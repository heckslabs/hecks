# = Hecks::Chapters::Runtime
#
# Self-describing chapter for the Hecks runtime layer. Covers the
# runtime container, command/event dispatch, ports, mixins, event
# sourcing, sagas, workflows, and domain versioning.
#
#   domain = Hecks::Chapters::Runtime.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    # Hecks::Chapters::Runtime
    #
    # Bluebook chapter defining the Hecks runtime: command dispatch, ports, mixins, event sourcing, and sagas.
    #
    module Runtime
      def self.summary = "Core kernel of the Hecks hexagonal DDD framework"

      def self.definition
        @definition ||= DSL::BluebookBuilder.new("Runtime").tap { |b|
          Chapters.define_paragraphs(Runtime, b)
        }.build
      end
    end
  end
end
