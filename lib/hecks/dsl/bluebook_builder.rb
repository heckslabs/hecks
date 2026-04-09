# Bootstrap: EventBuilder and StrategicBuilders are used at class-body
# time. Cannot use chapter-driven loading.
require "hecks/dsl/event_builder"
require "hecks/dsl/bluebook_builder/strategic_builders"

module Hecks
  module DSL

    # Hecks::DSL::BluebookBuilder
    #
    # Top-level DSL builder for domain definitions. Collects aggregate definitions
    # and domain-level policies, then builds a BluebookModel::Structure::Domain.
    # Enforces unique aggregate names. Domain-level policies are cross-aggregate
    # reactive policies defined outside any aggregate block.
    #
    #   Hecks.bluebook "Banking" do
    #     aggregate "Loan" do ... end
    #     aggregate "Account" do ... end
    #
    #     policy "DisburseFunds" do
    #       on "IssuedLoan"
    #       trigger "Deposit"
    #       map principal: :amount
    #     end
    #   end
    #
    # Builds a BluebookModel::Structure::Domain from top-level DSL declarations.
    #
    # BluebookBuilder is the entry point for defining an entire domain model. It
    # collects aggregate definitions, cross-aggregate reactive policies, domain
    # services, read model views, workflows, event subscribers, and tenancy
    # configuration. The +#build+ method assembles these into an immutable
    # Domain IR (intermediate representation) object.
    #
    # Aggregates names must be unique within a domain; attempting to define
    # a duplicate raises +ArgumentError+. Errors within aggregate blocks are
    # wrapped in +Hecks::ValidationError+ with context about which aggregate
    # failed.
    #
    # Includes AttributeCollector for domain-level attribute declarations
    # (rarely used, but available for domain metadata).
    class BluebookBuilder
      Structure = BluebookModel::Structure

      include AttributeCollector
      include Describable
      include Hecksagon::ExtensionsDSL if defined?(Hecksagon::ExtensionsDSL)
      include Hecksagon::StrategicDSL if defined?(Hecksagon::StrategicDSL)

      # Initialize a new domain builder with the given domain name.
      #
      # Sets up empty collections for all domain-level elements.
      #
      # @param name [String] the domain name (e.g. "Banking", "PizzaShop")
      # @param version [String, nil] optional version string (semver or CalVer)
      def initialize(name, version: nil)
        @name = name
        @version = version
        @aggregates = []
        @paragraphs = []
        @policies = []
        @services = []
        @views = []
        @workflows = []
        @attributes = []
        @actors = []
        @sagas = []
        @glossary_rules = []
        @modules = []
        @tenancy = nil
        @event_subscribers = []
        @world_concerns = []
        @entry_points = []
        @vision = nil
        @subdomain = nil
        @glossary_terms = []
      end

      # Declare world concerns that this domain aspires to uphold.
      # Concerns activate corresponding validation rules that check domain design
      # for alignment. Available concerns: :transparency, :consent, :privacy, :security.
      #
      #   world_concerns :transparency, :consent, :privacy
      #
      # @param concerns [Array<Symbol>] one or more concern names
      # @return [void]
      def world_concerns(*concerns)
        @world_concerns.concat(concerns.map(&:to_sym))
      end

      # Set the strategic vision statement for this domain.
      # Describes what problem the domain solves in business terms.
      #
      #   vision "Manage pizza creation and ordering for a pizzeria"
      #
      # @param text [String] the vision statement
      # @return [void]
      def vision(text)
        @vision = text
      end

      # Classify this domain's subdomain type (Evans strategic design).
      #
      #   subdomain :core
      #
      # @param type [Symbol] one of :core, :supporting, :generic
      # @return [void]
      def subdomain(type)
        @subdomain = type.to_sym
      end

      # Shorthand for subdomain(:core)
      def core;       subdomain(:core);       end
      # Shorthand for subdomain(:supporting)
      def supporting; subdomain(:supporting); end
      # Shorthand for subdomain(:generic)
      def generic;    subdomain(:generic);    end

      # Define a glossary term with its business definition.
      # Builds the ubiquitous language dictionary for this domain.
      #
      #   define "Topping", "A measured ingredient placed on a pizza"
      #   define "Order", "A customer's request for one or more pizzas"
      #
      # @param term [String] the domain term name
      # @param definition [String] what this term means in the domain
      # @return [void]
      def define(term, definition)
        @glossary_terms << { name: term.to_s, definition: definition.to_s }
      end

      def actor(name, description: nil)
        @actors << Structure::Actor.new(name: name.to_s, description: description)
      end


      # Saga for long-running cross-aggregate coordination.
      #   saga "OrderFulfillment" do
      #     step "ReserveInventory" do
      #       on_success "InventoryReserved"
      #       compensate "ReleaseInventory"
      #     end
      #     timeout "48h"
      #     on_timeout "CancelOrder"
      #   end
      def saga(name, &block)
        builder = SagaBuilder.new(name)
        builder.instance_eval(&block) if block
        @sagas << builder.build
      end

      # Ubiquitous language enforcement.
      #   glossary do
      #     prefer "stakeholder", not: ["user", "person"]
      #   end
      #   glossary(strict: true) do
      #     prefer "stakeholder", not: ["user", "person"]
      #   end
      def glossary(strict: false, &block)
        @glossary_strict = strict
        gb = GlossaryBuilder.new(@glossary_rules)
        gb.instance_eval(&block) if block
      end

      # Logical sub-grouping within the domain.
      #   domain_module "PolicyManagement" do
      #     aggregate "GovernancePolicy" do ... end
      #   end
      def domain_module(name, &block)
        mod = { name: name, aggregates: [] }
        if block
          sub = ModuleBuilder.new(name, self)
          sub.instance_eval(&block)
          mod[:aggregates] = sub.aggregate_names
        end
        @modules << mod
      end

      # Set the multi-tenancy strategy for this domain.
      #
      # Deprecated: tenancy moved to Hecksagon. Kept as no-op for compatibility.
      def tenancy(_strategy); end

      # Define a domain service with the given name and optional configuration block.
      #
      # Domain services orchestrate operations that span multiple aggregates.
      # The block is evaluated in the context of a ServiceBuilder.
      #
      # @param name [String] the service name (e.g. "TransferMoney")
      # @yield block evaluated in the context of ServiceBuilder
      # @return [void]
      def service(name, &block)
        builder = ServiceBuilder.new(name)
        builder.instance_eval(&block) if block
        @services << builder.build
      end

      # Register a domain-level event subscriber for the given event.
      #
      # Domain-level subscribers react to events from any aggregate in the
      # domain. They are distinct from aggregate-level subscribers which
      # are scoped to a single aggregate.
      #
      # @param event_name [Symbol, String] the event name to subscribe to
      # @yield block invoked when the event fires
      # @return [void]
      def on_event(event_name, &block)
        @event_subscribers << BluebookModel::SubscriberRegistration.new(
          event_name: event_name.to_s, block: block
        )
      end

      # Load partial domain definitions from a file.
      #
      # Reads the given file and evaluates its contents within this builder's
      # context, allowing domain definitions to be split across multiple files.
      # The path is resolved relative to +@_source_dir+ (if set) or +Dir.pwd+.
      #
      # @param path [String] relative or absolute path to a Ruby file containing DSL definitions
      # @return [void]
      #
      # @example
      #   load_from "domain/aggregates/models.rb"
      def load_from(path)
        full = File.expand_path(path, @_source_dir || Dir.pwd)
        instance_eval(File.read(full), full, 1)
      end

      # Define an aggregate root; raises on duplicate names.
      #
      # Creates an AggregateBuilder, evaluates the block within it, and adds
      # the resulting Aggregate IR to the domain. Duplicate aggregate names
      # raise +ArgumentError+. Errors within the block (other than Hecks::Error
      # subclasses) are wrapped in +Hecks::ValidationError+ with context.
      #
      # @param name [String] the aggregate root name (e.g. "Pizza", "Account")
      # @yield block evaluated in the context of AggregateBuilder
      # @return [void]
      # @raise [ArgumentError] if an aggregate with the same name already exists
      # @raise [Hecks::ValidationError] if the block raises a non-Hecks error
      def aggregate(name, description = nil, definition: nil, &block)
        if @aggregates.any? { |a| a.name == name }
          raise ArgumentError, "Duplicate aggregate name: #{name}"
        end

        builder = AggregateBuilder.new(name)
        desc = definition || description
        builder.description(desc) if desc
        begin
          builder.instance_eval(&block) if block
        rescue Hecks::Error
          raise
        rescue => e
          raise Hecks::ValidationError, "Error in aggregate '#{name}': #{e.message}"
        end
        @aggregates << builder.build
      end

      # Define a paragraph — a named group of aggregates within a chapter.
      #
      # Paragraphs organize a chapter's aggregates into focused sections.
      # The block receives the builder so aggregates can be defined inside it.
      #
      #   paragraph "Ports" do
      #     aggregate "EventBus" do ... end
      #     aggregate "CommandBus" do ... end
      #   end
      #
      # @param name [String] the paragraph name (e.g. "Ports")
      # @yield block evaluated in the context of BluebookBuilder (self)
      # @return [void]
      def paragraph(name, &block)
        before = @aggregates.dup
        instance_eval(&block) if block
        added = @aggregates - before
        @paragraphs << Structure::Paragraph.new(name: name, aggregates: added)
      end

      # Declare an autoload entry point file for this domain.
      # Entry points are the top-level .rb files that set up autoloads
      # and namespace modules (e.g., "hecks_persist", "hecks_mongodb").
      #
      #   entry_point "hecks_persist"
      #
      def entry_point(name)
        @entry_points << name.to_s
      end

      # Define a cross-aggregate reactive policy.
      #
      # Domain-level policies react to events from one aggregate and trigger
      # commands on another, enabling decoupled cross-context workflows.
      # The block is evaluated in the context of a PolicyBuilder.
      #
      # @param name [String] the policy name (e.g. "DisburseFunds")
      # @yield block evaluated in the context of PolicyBuilder
      # @return [void]
      def policy(name, &block)
        builder = PolicyBuilder.new(name)
        builder.instance_eval(&block) if block
        @policies << builder.build
      end

      # Define a read model (view) projected from domain events.
      #
      # Read models are denormalized projections built by applying event
      # handlers. The block is evaluated in the context of a ReadModelBuilder.
      #
      # @param name [String] the read model name (e.g. "OrderSummary")
      # @yield block evaluated in the context of ReadModelBuilder
      # @return [void]
      def view(name, &block)
        builder = ReadModelBuilder.new(name)
        builder.instance_eval(&block) if block
        @views << builder.build
      end

      # Define a multi-step workflow composed of commands and branches.
      #
      # Workflows orchestrate sequences of commands with optional branching
      # logic based on specification predicates. The block is evaluated in
      # the context of a WorkflowBuilder.
      #
      # @param name [String] the workflow name (e.g. "LoanApproval")
      # @yield block evaluated in the context of WorkflowBuilder
      # @return [void]
      def workflow(name, &block)
        builder = WorkflowBuilder.new(name)
        builder.instance_eval(&block) if block
        @workflows << builder.build
      end

      # Implicit DSL support. PascalCase calls at the domain level create aggregates.
      # Example: `Pizza do ... end` is sugar for `aggregate "Pizza" do ... end`
      def method_missing(name, *args, **kwargs, &block)
        if name.to_s =~ /\A[A-Z]/ && block_given?
          desc = args.first.is_a?(String) ? args.first : nil
          aggregate(name.to_s, desc, **kwargs, &block)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        name.to_s =~ /\A[A-Z]/ || super
      end

      # Build and return the BluebookModel::Structure::Domain IR object.
      #
      # Assembles all collected domain-level elements into an immutable
      # Domain intermediate representation.
      #
      # @return [BluebookModel::Structure::Domain] the fully built domain IR object
      def build
        domain = Structure::Domain.new(
          name: @name, version: @version, aggregates: @aggregates, paragraphs: @paragraphs, policies: @policies,
          services: @services, views: @views, workflows: @workflows,
          actors: @actors, tenancy: @tenancy,
          event_subscribers: @event_subscribers,
          sagas: @sagas, glossary_rules: @glossary_rules, modules: @modules,
          glossary_strict: @glossary_strict || false,
          world_concerns: @world_concerns,
          description: @description,
          entry_points: @entry_points,
          vision: @vision, subdomain: @subdomain,
          glossary_terms: @glossary_terms
        )
        classify_references(domain)
        if domain.respond_to?(:driving_ports=)
          domain.driving_ports = @driving_ports || []
          domain.driven_ports = @driven_ports || []
          domain.shared_kernel = @shared_kernel || false
          domain.uses_kernels = @uses_kernels || []
          domain.anti_corruption_layers = @anti_corruption_layers || []
          domain.published_events = @published_events || []
        end
        domain
      end

      private

      def classify_references(domain)
        agg_names = domain.aggregates.map(&:name)
        domain.aggregates.each do |agg|
          local_types = agg.value_objects.map(&:name) + agg.entities.map(&:name)
          (agg.references || []).each do |ref|
            ref.kind = if ref.domain
                         :cross_context
                       elsif local_types.include?(ref.type)
                         :composition
                       elsif agg_names.include?(ref.type)
                         :aggregation
                       else
                         :aggregation
                       end
          end
        end
      end
    end
  end
end
