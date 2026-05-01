module Hecks
  class Workshop
    class WebRunner
      class StateSerializer
        # Hecks::Workshop::WebRunner::StateSerializer::ServiceSerializer
        #
        # Serializes domain services across all loaded domains into
        # JSON-ready hashes with name, domain, and attributes.
        #
        #   ServiceSerializer.new(domains).call
        #   # => [{ name: "PlaceOrder", domain: "Pizzas", attributes: [...] }]
        #
        class ServiceSerializer
          def initialize(domains)
            @domains = domains
          end

          def call
            @domains.flat_map do |domain|
              domain.services.map do |svc|
                svc_attrs = svc.attributes.map { |a| { name: a.name, type: a.type.to_s } }
                { name: svc.name, domain: domain.name, attributes: svc_attrs }
              end
            end
          rescue
            []
          end
        end
      end
    end
  end
end
