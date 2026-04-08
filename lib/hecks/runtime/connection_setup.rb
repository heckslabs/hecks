# Hecks::Runtime::ConnectionSetup
#
# Mixin that wires domain connections declared via BluebookConnections
# (listens_to and sends_to) onto the event bus at boot time. Also exposes
# the event bus on the domain module for cross-domain subscriptions.
#
# Part of Runtime. Consumed after repositories and policies are set up.
#
#   class Runtime
#     include ConnectionSetup
#   end
#
module Hecks
  class Runtime
      # Handles cross-domain event wiring for a Runtime instance. When a domain
      # declares +listens_to+ connections, this module subscribes to the source
      # domain's event bus and forwards events into the local bus. When a domain
      # declares +sends_to+ connections, this module subscribes to the local bus
      # and forwards events to the outbound handler (adapter or callable).
      #
      # Also exposes the event bus as an instance variable on the domain module,
      # enabling other domains to subscribe via +SomeDomain.event_bus+.
      module ConnectionSetup
        private

        # Orchestrates connection wiring: exposes the event bus on the domain module,
        # then wires any +listens_to+ and +sends_to+ connections declared via
        # +BluebookConnections+.
        #
        # @return [void]
        def setup_connections
          expose_event_bus

          return unless @mod.respond_to?(:connections)

          wire_listens_to(@mod.connections[:listens])
          wire_sends_to(@mod.connections[:sends])
        end

        # Store the event bus on the domain module as +@event_bus+ so other domains
        # can access it via +SomeDomain.event_bus+ for cross-domain subscriptions.
        #
        # @return [void]
        def expose_event_bus
          bus = @event_bus
          @mod.instance_variable_set(:@event_bus, bus)
        end

        # Subscribe to each source domain's event bus, forwarding all events
        # into the local domain's event bus. Warns if a source domain's event bus
        # is not available (e.g., if the source domain has not been booted yet).
        #
        # @param sources [Array<Module>, nil] source domain modules that have an +.event_bus+ method
        # @return [void]
        def wire_listens_to(sources)
          return unless sources&.any?

          sources.each do |source|
            unless source.respond_to?(:event_bus) && source.event_bus
              warn "[Hecks] Cannot listen to #{source} — no event bus (not yet booted?)"
              next
            end

            our_bus = @event_bus
            source.event_bus.on_any { |event| our_bus.publish(event) }
          end
        end

        # Subscribe to the local event bus and forward all events to each outbound
        # target handler. Handlers can be callable objects (responding to +.call+)
        # or adapter objects (responding to +.publish+).
        #
        # @param targets [Array<Hash>, nil] target entries, each containing a +:handler+ key
        #   whose value responds to +.call+ or +.publish+
        # @return [void]
        def wire_sends_to(targets)
          return unless targets&.any?

          targets.each do |target|
            handler = target[:handler]
            next unless handler

            @event_bus.on_any do |event|
              if handler.respond_to?(:call)
                handler.call(event)
              elsif handler.respond_to?(:publish)
                handler.publish(event)
              end
            end
          end
        end
      end
  end
end
