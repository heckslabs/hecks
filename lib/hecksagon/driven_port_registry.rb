  # Hecksagon::DrivenPortRegistry
  #
  # Formalizes adapter registration for driven ports.
  #
  #   Hecksagon.register_adapter(:sqlite, for: :persistence) do |config|
  #     # wiring logic
  #   end
  #
  #   Hecksagon.adapters_for(:persistence)  # => [:memory, :sqlite]
  #   Hecksagon.adapter(:sqlite)            # => { gate: :persistence, hook: Proc }
  #
module Hecksagon

  module DrivenPortRegistry
    def adapter_registry
      @adapter_registry ||= {}
    end

    def register_adapter(name, for_port: nil, implements: [], &hook)
      adapter_registry[name.to_sym] = {
        name: name.to_sym,
        gate: for_port&.to_sym,
        implements: implements.map(&:to_sym),
        hook: hook
      }
    end

    def adapter(name)
      adapter_registry[name.to_sym]
    end

    def adapters_for(port_name)
      adapter_registry.values
        .select { |a| a[:port] == port_name.to_sym }
        .map { |a| a[:name] }
    end

    def all_adapters
      adapter_registry.keys
    end
  end
end
