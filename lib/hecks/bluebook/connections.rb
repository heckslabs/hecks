module Hecks
  # Hecks::BluebookConnections
  #
  # Mixin extended onto generated domain modules (e.g., PizzasDomain) to declare
  # what crosses the domain boundary. One verb: `extend`.
  #
  #   app = Hecks.boot(__dir__) do
  #     extend :sqlite                           # persist
  #     extend :tenancy                          # middleware
  #     extend :slack, webhook: ENV["SLACK_URL"] # outbound events
  #     extend CommentsDomain                    # listen to domain events
  #   end
  #
  module BluebookConnections
    # Unified extension method. Dispatches based on argument type:
    #
    #   extend CommentsDomain              # Module → listen to their events
    #   extend :sqlite                     # Symbol (persistence) → persist to adapter
    #   extend :tenancy                    # Symbol (middleware) → add middleware
    #   extend :slack, webhook: url        # Symbol + opts → outbound events
    #   extend :audit, ->(e) { log(e) }   # Symbol + handler → outbound events
    #
    # @param target [Module, Symbol] domain module or extension name
    # @param args [Array] additional arguments (adapter, handler, etc.)
    # @param kwargs [Hash] options passed through
    # @param block [Proc] optional handler block (for outbound events)
    # @return [void]
    def extend(target, *args, **kwargs, &block)
      if target.is_a?(Module)
        listen_to(target)
      elsif target.is_a?(Symbol)
        if args.first.respond_to?(:call) || block
          send_to(target, args.first, **kwargs, &block)
        elsif persistence_type?(target)
          persist(target, **kwargs)
        elsif kwargs.any? && !persistence_type?(target)
          send_to(target, nil, **kwargs, &block)
        else
          use_extension(target, **kwargs)
        end
      else
        super
      end
    end

    # Return the current connection configuration hash.
    #
    # @return [Hash{Symbol => Hash, Array}]
    def connections
      @connections || default_connections
    end

    # Expose the event bus set by Runtime for cross-domain subscriptions.
    #
    # @return [Hecks::EventBus, nil]
    def event_bus
      @event_bus
    end

    private

    def persistence_type?(name)
      Hecks.adapter?(name)
    end

    def persist(type, as: :default, **options)

      @connections ||= default_connections
      @connections[:persist][as] = PersistConfig.new(type: type, **options)
    end

    def listen_to(source)
      @connections ||= default_connections
      @connections[:listens] << source
    end

    def send_to(name, adapter = nil, **options, &block)

      @connections ||= default_connections
      handler = adapter || block
      @connections[:sends] << SendConfig.new(name: name, handler: handler, **options)
    end

    def use_extension(name, **kwargs)

      @connections ||= default_connections
      @connections[:extensions] << ExtensionConfig.new(name: name, **kwargs)
    end

    def default_connections
      { persist: {}, listens: [], sends: [], extensions: [] }
    end
  end
end
