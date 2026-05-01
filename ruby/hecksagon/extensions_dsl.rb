  # Hecksagon::ExtensionsDSL
  #
  # Mixin for domain builders. Declares how the domain connects to
  # the outside world — inbound interfaces and outbound dependencies.
  #
  #   driving_port :http, description: "REST API"
  #   driven_port :persistence, [:find, :save, :delete, :all]
  #
module Hecksagon

  module ExtensionsDSL
    def self.included(base)
      base.class_eval do
        def init_extensions
          @driving_ports ||= []
          @driven_ports ||= []
        end
      end
    end

    # Declare an inbound interface (driving/primary port).
    #   driving_port :http, description: "REST API"
    #   driving_port :mcp, description: "AI tool interface"
    def driving_port(name, description: nil)
      init_extensions
      @driving_ports << { name: name.to_sym, description: description }
    end

    # Declare an outbound dependency (driven/secondary port).
    #   driven_port :persistence, [:find, :save, :delete, :all]
    #   driven_port :notifications, [:send_email, :send_sms]
    def driven_port(name, methods = [], description: nil)
      init_extensions
      @driven_ports << { name: name.to_sym, methods: methods.map(&:to_sym), description: description }
    end
  end
end
