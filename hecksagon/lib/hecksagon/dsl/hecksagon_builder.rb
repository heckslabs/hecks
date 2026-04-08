module Hecksagon
  module DSL

    # Hecksagon::DSL::HecksagonBuilder
    #
    # DSL builder for hexagonal architecture wiring. Collects gates, adapter
    # config, extensions, cross-domain subscriptions, and tenancy strategy.
    #
    #   builder = HecksagonBuilder.new("Pizzas")
    #   builder.gate("Pizza", :admin) { allow :find, :all }
    #   builder.adapter :sqlite, database: "app.db"
    #   hex = builder.build
    #
    class HecksagonBuilder
      def initialize(name = nil)
        @name = name
        @gates = []
        @adapter = nil
        @extensions = []
        @subscriptions = []
        @tenancy = nil
        @capabilities = []
        @aggregate_capabilities = {}
        @annotations = []
      end

      # Declare a gate (access control) for an aggregate + role.
      #
      # @param aggregate [String] the aggregate name
      # @param role [Symbol] the role name
      # @yield block evaluated in GateBuilder context
      # @return [void]
      def gate(aggregate, role, &block)
        builder = GateBuilder.new(aggregate, role)
        builder.instance_eval(&block) if block
        @gates << builder.build
      end

      # Configure the persistence adapter.
      #
      # @param type [Symbol] adapter type (:memory, :sqlite, :postgres, etc.)
      # @param options [Hash] adapter-specific options (e.g., database:, host:)
      # @return [void]
      def adapter(type, **options)
        @adapter = { type: type }.merge(options)
      end

      # Register an extension.
      #
      # @param name [Symbol] extension name (e.g., :audit, :rate_limit)
      # @param options [Hash] extension-specific options
      # @return [void]
      def extension(name, **options)
        @extensions << { name: name.to_sym }.merge(options)
      end

      # Subscribe to events from another domain.
      #
      # @param domain_name [String] the source domain to listen to
      # @return [void]
      def subscribe(domain_name)
        @subscriptions << domain_name.to_s
      end

      # Declare domain-wide capabilities.
      #
      #   capabilities :crud, :audit
      #
      # @param names [Array<Symbol>] capability names
      # @return [void]
      def capabilities(*names)
        @capabilities.concat(names.map(&:to_sym))
      end

      # Declare per-aggregate capabilities via a block. The block
      # receives an AggregateCapabilityBuilder for fluent tagging.
      #
      #   aggregate "Pizza" do
      #     capability.email.pii
      #   end
      #
      # @param name [String] the aggregate name (must exist in domain)
      # @yield block evaluated in AggregateCapabilityBuilder context
      # @return [void]
      def aggregate(name, &block)
        builder = AggregateCapabilityBuilder.new(name)
        builder.instance_eval(&block) if block
        @aggregate_capabilities[name.to_s] = builder.tags
      end

      # Set the multi-tenancy strategy.
      #
      # @param strategy [Symbol] tenancy strategy (:row, :schema, etc.)
      # @return [void]
      def tenancy(strategy)
        @tenancy = strategy.to_sym
      end

      # Handle PascalCase names as aggregate annotation chains.
      # Enables: Chat.prompt.ai_responder adapter: :claude
      #
      # @return [AnnotationSelector]
      def method_missing(name, *args, &block)
        if name.to_s.match?(/\A[A-Z]/)
          AnnotationSelector.new(@annotations, name.to_s)
        else
          super
        end
      end

      def respond_to_missing?(name, _ = false)
        name.to_s.match?(/\A[A-Z]/) || super
      end

      # Build and return the Hecksagon IR object.
      #
      # @return [Hecksagon::Structure::Hecksagon]
      def build
        Structure::Hecksagon.new(
          name: @name,
          gates: @gates,
          adapter: @adapter,
          extensions: @extensions,
          subscriptions: @subscriptions,
          tenancy: @tenancy,
          capabilities: @capabilities,
          aggregate_capabilities: @aggregate_capabilities,
          annotations: @annotations
        )
      end
    end

    # Fluent builder for per-aggregate capability tags.
    #
    #   builder = AggregateCapabilityBuilder.new("Pizza")
    #   builder.capability.email.pii
    #   builder.tags  # => [{ attribute: "email", tag: :pii }]
    #
    class AggregateCapabilityBuilder
      attr_reader :tags

      def initialize(aggregate_name)
        @aggregate_name = aggregate_name
        @tags = []
      end

      # Start a capability chain. Returns an AttributeSelector.
      #
      #   capability.email.pii
      #
      # @return [AttributeSelector]
      def capability
        AttributeSelector.new(@tags)
      end

      # Fluent attribute selector for capability tagging.
      class AttributeSelector
        def initialize(tags)
          @tags = tags
        end

        def method_missing(attr_name, *args)
          TagApplier.new(@tags, attr_name.to_s)
        end

        def respond_to_missing?(_, _ = false) = true
      end

      # Applies a tag to the selected attribute.
      class TagApplier
        def initialize(tags, attribute)
          @tags = tags
          @attribute = attribute
        end

        def method_missing(tag_name, *args)
          @tags << { attribute: @attribute, tag: tag_name.to_sym }
          self
        end

        def respond_to_missing?(_, _ = false) = true
      end
    end
  end
end
