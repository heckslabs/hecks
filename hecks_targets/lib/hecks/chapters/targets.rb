# Hecks::Chapters::Targets
#
# Self-describing domain definition for the Targets chapter. The code
# generation layer models itself as a domain: Target represents a
# language backend, with paragraphs for Go, Node, and Ruby generators.
#
#   domain = Hecks::Chapters::Targets.definition
#   domain.aggregates.map(&:name)
#
require_relative "targets/go"
require_relative "targets/node"
require_relative "targets/ruby"
require_relative "targets/schema"

module Hecks
  module Chapters
    module Targets
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Targets").tap { |b|
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

          Go.define(b)
          Node.define(b)
          Ruby.define(b)
          SchemaParagraph.define(b)
        }.build
      end
    end
  end
end
