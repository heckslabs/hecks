# Hecks::Chapters::Binding
#
# The Binding chapter holds chapters together: module wiring, shared
# utilities, error hierarchy, registries, contracts, cross-chapter
# event routing, and the compositor that loads and connects all chapters.
#
#   domain = Hecks::Chapters::Binding.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    # Hecks::Chapters::Binding
    #
    # Bluebook chapter for framework binding: module wiring, error hierarchy, registries, contracts, and event routing.
    #
    module Binding
      def self.definition
        @definition ||= DSL::BluebookBuilder.new("Binding").tap { |b|
          Chapters.define_paragraphs(Binding, b)
        }.build
      end
    end
  end
end
