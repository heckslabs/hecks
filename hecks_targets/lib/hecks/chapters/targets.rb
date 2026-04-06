# Hecks::Chapters::Targets
#
# Self-describing domain definition for the Targets chapter. The code
# generation layer models itself as a domain: Target represents a
# language backend (Ruby, Go, Node) that can be registered and built.
#
#   domain = Hecks::Chapters::Targets.definition
#   domain.aggregates.map(&:name)  # => ["Target"]
#
module Hecks
  module Chapters
    module Targets
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Targets").tap { |b|
          b.instance_eval do
            aggregate "Target" do
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
          end
        }.build
      end
    end
  end
end
