  # Hecksagon::StrategicDSL
  #
  # Mixin for domain builders. Adds strategic hexagonal patterns:
  # shared kernels, anti-corruption layers, published events.
  #
module Hecksagon

  module StrategicDSL
    def self.included(base)
      base.class_eval do
        def init_strategic
          @shared_kernel ||= false
          @uses_kernels ||= []
          @anti_corruption_layers ||= []
          @published_events ||= []
        end
      end
    end

    def shared_kernel
      init_strategic
      @shared_kernel = true
    end

    def uses_kernel(name)
      init_strategic
      @uses_kernels << name.to_s
    end

    # Anti-corruption layer for cross-domain translation.
    #   anti_corruption_layer "Billing" do
    #     translate "Invoice", billing_id: :invoice_number
    #   end
    def anti_corruption_layer(domain_name, &block)
      init_strategic
      acl = { domain: domain_name.to_s, translations: [] }
      Hecksagon::AclBuilder.new(acl).instance_eval(&block) if block
      @anti_corruption_layers << acl
    end

    # Versioned event contract for cross-context communication.
    #   published_event "ModelRegistered", version: 1 do
    #     attribute :model_id, String
    #   end
    def published_event(name, version: 1, &block)
      init_strategic
      builder = Hecks::DSL::EventBuilder.new(name)
      builder.instance_eval(&block) if block
      @published_events << { name: name, version: version, event: builder.build }
    end
  end
end
