  # Hecksagon::ContractValidator
  #
  # Validates that adapters satisfy their driven port contracts.
  # Called at boot time to catch wiring errors early.
  #
  #   errors = ContractValidator.validate(domain)
  #   # => ["Port :notifications has no adapter wired"]
  #   # => ["Adapter :sqlite missing method :query for port :persistence"]
  #
module Hecksagon

  module ContractValidator
    def self.validate(domain)
      errors = []
      return errors unless domain.respond_to?(:driven_ports) && domain.driven_ports

      domain.driven_ports.each do |port|
        adapters = Hecksagon.adapters_for(port[:name])
        if adapters.empty?
          errors << "Port :#{port[:name]} has no adapter registered"
          next
        end

        adapters.each do |adapter_name|
          adapter = Hecksagon.adapter(adapter_name)
          missing = port[:methods] - adapter[:implements]
          missing.each do |method|
            errors << "Adapter :#{adapter_name} missing method :#{method} for port :#{port[:name]}"
          end
        end
      end

      errors
    end
  end
end
