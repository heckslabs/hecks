module Hecks
  class Runtime
      # Hecks::Runtime::SubscriberSetup
      #
      # Mixin that wires DSL-defined event subscribers to the event bus at
      # boot time. Sync subscribers fire inline; async subscribers are passed
      # to the registered async handler.
      #
      #   class Runtime
      #     include SubscriberSetup
      #   end
      #
      module SubscriberSetup
        include HecksTemplating::NamingHelpers
        private

        # Wires all aggregate-level and domain-level event subscribers to the event bus.
        #
        # For each aggregate's subscribers:
        # 1. Resolves the subscriber class from +ModuleDomain::AggregateName::Subscribers::SubscriberName+
        # 2. Instantiates the subscriber (calling +.new+ once, shared across events)
        # 3. Subscribes to the declared event name on the event bus
        # 4. If the subscriber is async and an +@async_handler+ is registered,
        #    delegates to the async handler with the subscriber's fully-qualified class name;
        #    otherwise calls +handler.call(event)+ synchronously
        #
        # After aggregate subscribers, also wires domain-level event subscribers
        # via +setup_domain_event_subscribers+.
        #
        # @return [void]
        def setup_subscribers
          @domain.aggregates.each do |agg|
            agg.subscribers.each do |sub|
              safe_name = domain_constant_name(agg.name)
              sub_class = @mod.const_get(safe_name)::Subscribers.const_get(sub.name)
              handler = sub_class.new

              @event_bus.subscribe(sub.event_name) do |event|
                if sub.async && @async_handler
                  @async_handler.call("#{@mod_name}::#{safe_name}::Subscribers::#{sub.name}", event)
                else
                  handler.call(event)
                end
              end
            end
          end

          setup_domain_event_subscribers
        end

        # Wires domain-level event subscribers (defined via +on_event+ in the domain DSL).
        #
        # These are block-based subscribers stored as SubscriberRegistration structs
        # with +event_name+ and +block+ members. Each block is subscribed directly
        # to the event bus.
        #
        # Returns immediately if the domain does not support +event_subscribers+
        # (backward compatibility with older domain definitions).
        #
        # @return [void]
        def setup_domain_event_subscribers
          return unless @domain.respond_to?(:event_subscribers)

          @domain.event_subscribers.each do |sub|
            callback = sub.block
            @event_bus.subscribe(sub.event_name) do |event|
              callback.call(event)
            end
          end
        end
      end
  end
end
