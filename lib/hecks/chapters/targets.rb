# Hecks::Chapters::Targets
#
# Self-describing domain definition for the Targets chapter. The code
# generation layer models itself as a domain: Target represents a
# language backend, with paragraphs for Go, Node, and Ruby generators.
#
#   domain = Hecks::Chapters::Targets.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Targets
      def self.definition
        @definition ||= DSL::BluebookBuilder.new("Targets").tap { |b|
          b.aggregate "Target", "Language backend registration and build dispatch" do
            attribute :name, String
            attribute :language, String

            command "RegisterTarget" do
              attribute :name, String
              attribute :language, String
            end

            command "Build" do
              attribute :target_id, String
              attribute :domain_id, String
            end
          end

          Chapters.define_paragraphs(Targets, b)
        }.build
      end
    end
  end
end
