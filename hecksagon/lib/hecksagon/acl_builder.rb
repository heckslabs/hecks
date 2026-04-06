  # Hecksagon::AclBuilder
  #
  # Collects translations for an anti-corruption layer.
  #
  #   anti_corruption_layer "Billing" do
  #     translate "Invoice", billing_id: :invoice_number
  #   end
  #
module Hecksagon

  class AclBuilder
    def initialize(acl)
      @acl = acl
    end

    def translate(type, **mappings)
      @acl[:translations] << { type: type.to_s, mappings: mappings }
    end
  end
end
