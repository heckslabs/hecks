module Hecksagon
  module DSL

    # Hecksagon::DSL::HecksagonBuilder
    #
    # DSL builder for hexagonal architecture wiring. Collects gates, adapter
    # config, extensions, cross-domain subscriptions, and tenancy strategy.
    #
    #   builder = HecksagonBuilder.new("Pizzas")
    #   builder.gate("Pizza", :admin) { allow :find, :all }
    #   builder.persistence :sqlite, database: "app.db"
    #   hex = builder.build
    #
    class HecksagonBuilder
      def initialize(name = nil)
        @name = name
        @gates = []
        @persistence = nil
        @extensions = []
        @subscriptions = []
        @tenancy = nil
        @capabilities = []
        @aggregate_capabilities = {}
        @annotations = []
        @context_map = []
        @shell_adapters = []
      end

      # Declare context map relationships between bounded contexts.
      #
      #   context_map do
      #     upstream "Pizzas", downstream: "Billing", relationship: :anti_corruption
      #     shared_kernel "Pizzas", "Inventory", shared: ["ToppingName"]
      #   end
      #
      # @yield block evaluated in ContextMapBuilder context
      # @return [void]
      def context_map(&block)
        builder = ContextMapBuilder.new
        builder.instance_eval(&block)
        @context_map = builder.build
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

      # Declare an adapter. Dispatches on kind:
      #
      #   adapter :memory                    # persistence — unnamed, at most one
      #   adapter :sqlite, database: "x.db"  # persistence
      #   adapter :shell, name: :git_log do  # shell — named, many allowed
      #     command "git"
      #     args ["log", "{{range}}"]
      #   end
      #
      # For kind `:shell`, a unique `name:` is required and the adapter is
      # appended to `@shell_adapters`. For any other kind, the call is
      # treated as a persistence declaration (at most one per hecksagon;
      # last wins).
      #
      # @param kind [Symbol] adapter kind
      # @param name [Symbol, nil] required when kind == :shell
      # @param opts [Hash] kind-specific options
      # @yield optional block (used by :shell) evaluated in ShellAdapterBuilder
      def adapter(kind, name: nil, **opts, &block)
        if kind == :shell
          raise ArgumentError, "adapter :shell requires name: keyword" if name.nil?
          sym = name.to_sym
          existing_idx = @shell_adapters.index { |a| a.name == sym }
          if existing_idx && !@_shell_adapter_seeded_names&.include?(sym)
            raise ArgumentError, "shell adapter :#{name} already declared in this hecksagon"
          end
          builder = ShellAdapterBuilder.new(name)
          builder.instance_eval(&block) if block
          builder.apply_options(opts)
          built = builder.build
          if existing_idx
            @shell_adapters[existing_idx] = built
            @_shell_adapter_seeded_names.delete(sym)
          else
            @shell_adapters << built
          end
        else
          @persistence = { type: kind }.merge(opts)
        end
      end

      # Internal: mark adapters seeded from an earlier hecksagon block as
      # overridable by the current block. Used by Hecks.hecksagon's merge
      # path; not part of the DSL surface.
      def _seed_shell_adapter(adapter)
        @_shell_adapter_seeded_names ||= []
        @_shell_adapter_seeded_names << adapter.name
        @shell_adapters << adapter
      end

      # Configure the persistence adapter. Deprecated alias for
      # `adapter(kind, **opts)` — the grammar exposes `adapter`
      # uniformly across persistence and shell kinds.
      #
      # @deprecated use `adapter(kind, **opts)` instead
      # @param type [Symbol] adapter type (:sqlite, :postgres, etc.)
      # @param options [Hash] adapter-specific options
      # @return [void]
      def persistence(type, **options)
        unless @_persistence_deprecation_warned
          warn "[Hecksagon] `persistence :#{type}` is deprecated — use `adapter :#{type}` (same options)."
          @_persistence_deprecation_warned = true
        end
        adapter(type, **options)
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

      # Declare domain-wide capabilities. Supports except: for exclusions
      # from composite capabilities (concerns).
      #
      #   capabilities :crud, :webapp
      #   capabilities :webstack, except: [:tailwind]
      #
      # @param names [Array<Symbol>] capability names
      # @param except [Array<Symbol>] capabilities to exclude
      # @return [void]
      def capabilities(*names, except: [], env: nil)
        if env && !env_matches?(env)
          return # skip capabilities not matching current environment
        end
        @capabilities.concat(names.map(&:to_sym))
        @excluded_capabilities ||= []
        @excluded_capabilities.concat(Array(except).map(&:to_sym))
      end

      # Declare concerns — bundles of capabilities.
      # Supports env: to restrict to specific environments.
      #
      #   concerns :webapp
      #   concerns :dev_tools, env: :development
      #
      # Register an annotation directly by strings, avoiding constant resolution.
      # Use when the domain is already compiled and PascalCase names would
      # resolve to existing constants instead of going through const_missing.
      #
      #   annotate "Workbench", "show_workbench", :workbench
      #   annotate "Collaboration::Agent", "content", :ai_responder, emits: "Replied"
      #
      def annotate(aggregate, attribute, annotation, **opts)
        @annotations << { aggregate: aggregate, attribute: attribute, annotation: annotation.to_sym }.merge(opts)
      end

      def concerns(*names, except: [], env: nil)
        if env && !env_matches?(env)
          return # skip concerns not matching current environment
        end
        @concerns ||= []
        @concerns.concat(names.map(&:to_sym))
        @excluded_capabilities ||= []
        @excluded_capabilities.concat(Array(except).map(&:to_sym))
      end

      # Declare driving (primary/user-side) ports. These are capabilities
      # that drive the application — UI, API, CLI, tests.
      #
      #   driving :webapp, :cli
      #
      # @param names [Array<Symbol>] port names
      # @param except [Array<Symbol>] capabilities to exclude
      # @return [void]
      def driving(*names, except: [])
        names.each { |n| @capabilities << n.to_sym }
        @driving_ports ||= []
        @driving_ports.concat(names.map(&:to_sym))
        @excluded_capabilities ||= []
        @excluded_capabilities.concat(Array(except).map(&:to_sym))
      end

      # Declare driven (secondary/infrastructure) ports. These are capabilities
      # driven by the application — persistence, messaging, external services.
      #
      #   driven :persistence, :email
      #
      # @param names [Array<Symbol>] port names
      # @return [void]
      def driven(*names)
        names.each { |n| @capabilities << n.to_sym }
        @driven_ports ||= []
        @driven_ports.concat(names.map(&:to_sym))
      end

      # Declare a port contract — the shape an adapter must satisfy.
      #
      #   port :persistence do
      #     requires :save, :find, :delete
      #     accepts  "Pizza"
      #     publishes "PizzaSaved"
      #   end
      #
      # @param name [Symbol] port name
      # @yield block evaluated in PortContractBuilder context
      # @return [void]
      def port(name, &block)
        builder = PortContractBuilder.new(name)
        builder.instance_eval(&block)
        @port_contracts ||= []
        @port_contracts << builder.build
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
        if Hecks::DSL::TypeName.match?(name.to_s)
          AnnotationSelector.new(@annotations, name.to_s)
        else
          super
        end
      end

      def respond_to_missing?(name, _ = false)
        Hecks::DSL::TypeName.match?(name.to_s) || super
      end

      # Build and return the Hecksagon IR object.
      #
      # @return [Hecksagon::Structure::Hecksagon]
      def build
        Structure::Hecksagon.new(
          name: @name,
          gates: @gates,
          persistence: @persistence,
          extensions: @extensions,
          subscriptions: @subscriptions,
          tenancy: @tenancy,
          capabilities: @capabilities,
          concerns: @concerns || [],
          excluded_capabilities: @excluded_capabilities || [],
          aggregate_capabilities: @aggregate_capabilities,
          annotations: @annotations,
          context_map: @context_map.any? ? @context_map : infer_context_map,
          driving_ports: @driving_ports || [],
          driven_ports: @driven_ports || [],
          port_contracts: @port_contracts || [],
          shell_adapters: @shell_adapters
        )
      end

      private

      # Check if the current environment matches.
      # Reads HECKS_ENV, RACK_ENV, RAILS_ENV, or defaults to :development.
      def env_matches?(required_env)
        current = (ENV["HECKS_ENV"] || ENV["RACK_ENV"] || ENV["RAILS_ENV"] || "development").to_sym
        Array(required_env).map(&:to_sym).include?(current)
      end

      # Infer context map from subscribe declarations.
      # Each subscription implies this context listens to events from another.
      def infer_context_map
        @subscriptions.map do |sub|
          { type: :upstream_downstream, source: sub, target: @name, relationship: :conformist }
        end
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
