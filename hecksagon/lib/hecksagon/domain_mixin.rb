  # Hecksagon::DomainMixin
  #
  # Extends Domain IR objects with hexagonal accessors.
  # Applied automatically when heksagons is loaded.
  #
module Hecksagon

  module DomainMixin
    attr_accessor :driving_ports, :driven_ports,
                  :shared_kernel, :uses_kernels,
                  :anti_corruption_layers, :published_events

    def shared_kernel?
      @shared_kernel == true
    end
  end
end
