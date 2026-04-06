# Hecks::Chapters::Hecksagon
#
# Self-describing domain definition for the Hecksagon chapter. The
# hexagonal wiring layer models itself as a domain: Gate handles
# access control, Extension handles infrastructure capabilities.
#
#   domain = Hecks::Chapters::Hecksagon.definition
#   domain.aggregates.map(&:name)  # => ["Gate", "Extension"]
#
module Hecks
  module Chapters
    module Hecksagon
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Hecksagon").tap { |b|
          b.instance_eval do
            aggregate "Gate" do
              attribute :aggregate_name, String
              attribute :role, String

              command "DefineGate" do
                attribute :aggregate_name, String
                attribute :role, String
              end

              command "AllowMethod" do
                attribute :gate_id, String
                attribute :method_name, String
              end
            end

            aggregate "Extension" do
              attribute :name, String
              attribute :adapter_type, String

              command "RegisterExtension" do
                attribute :name, String
                attribute :adapter_type, String
              end

              command "ActivateExtension" do
                attribute :extension_id, String
              end
            end
          end
        }.build
      end
    end
  end
end
