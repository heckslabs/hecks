module Hecks
  module DomainModel
    module Structure

    # Hecks::DomainModel::Structure::Domain
    #
    # The root of the domain model intermediate representation. A domain holds
    # aggregates and domain-level policies, and provides helpers for naming
    # (module_name, gem_name), introspection (describe), glossary output
    # (glossary), and Mermaid visualization (to_mermaid, visualize).
    # Domain-level policies are cross-aggregate reactive policies that don't
    # belong to any single aggregate.
    #
    # Part of the DomainModel IR layer. Built by DomainBuilder, consumed by every
    # generator and by the Application/Session at runtime.
    #
    #   domain = Domain.new(name: "Pizzas", aggregates: [pizza_agg, order_agg])
    #   domain.gem_name    # => "pizzas_domain"
    #   domain.describe    # prints aggregate tree with commands, queries, policies
    #   domain.glossary    # prints domain term glossary
    #   domain.visualize   # prints Mermaid diagrams (structure + behavior)
    #
    class Domain
      include Hecksagon::DomainMixin if defined?(Hecksagon::DomainMixin)

      # @return [String] the human-readable domain name (e.g., "Pizzas", "Accounting")
      attr_reader :name

      # @return [Array<Aggregate>] the aggregates that make up this domain
      attr_reader :aggregates

      # @return [Array<Behavior::Policy>] cross-aggregate reactive policies at the domain level.
      #   These policies listen for events from one aggregate and trigger commands on another.
      attr_reader :policies

      # @return [Array] domain services that orchestrate cross-aggregate operations
      attr_reader :services

      # @return [Array] view definitions for read-side projections
      attr_reader :views

      # @return [Array] workflow definitions that coordinate multi-step processes
      attr_reader :workflows

      # @return [Array<String>] custom HTTP verbs beyond the standard CRUD set,
      #   used by the serve extension for non-standard API endpoints
      attr_reader :custom_verbs

      # @return [Object, nil] tenancy configuration for multi-tenant domains.
      #   When set, the runtime scopes all repository operations to the current tenant.
      attr_reader :tenancy

      # @return [Array<Actor>] actors (roles) that interact with this domain
      attr_reader :actors



      # @return [Array<Hash>] saga/process manager definitions
      attr_reader :sagas

      # @return [Array<Hash>] ubiquitous language rules
      attr_reader :glossary_rules

      # @return [Boolean] true if glossary violations are treated as errors instead of warnings
      attr_reader :glossary_strict

      # @return [Array<Paragraph>] named groups of aggregates within this domain.
      #   Paragraphs organize a chapter's aggregates into focused sections.
      attr_reader :paragraphs

      # @return [Array<Hash>] logical module groupings within this domain
      attr_reader :modules

      # @return [Array<Symbol>] declared world concerns for this domain
      #   (e.g. :transparency, :consent, :privacy, :security)
      attr_reader :world_concerns

      # @return [Array<DomainModel::SubscriberRegistration>] event subscriber registrations at the domain level
      attr_reader :event_subscribers

      # @return [String, nil] the filesystem path where this domain's source files live.
      #   Set after compilation or when loading from a gem. Used by generators to know
      #   where to write output files.
      attr_accessor :source_path

      # @return [String, nil] the declared domain version (semver or CalVer), or nil if unset.
      attr_reader :version

      # Creates a new Domain IR node.
      #
      # @param name [String] the domain name (e.g., "Pizzas"). Used to derive module_name and gem_name.
      # @param aggregates [Array<Aggregate>] the aggregates in this domain
      # @param policies [Array<Behavior::Policy>] domain-level cross-aggregate policies
      # @param services [Array] domain service definitions
      # @param views [Array] view/projection definitions
      # @param workflows [Array] workflow definitions for multi-step processes
      # @param custom_verbs [Array<String>] custom HTTP verbs for the serve extension
      # @param tenancy [Object, nil] tenancy configuration, or nil for single-tenant
      # @param event_subscribers [Array] domain-level event subscriber registrations
      #
      # @return [Domain] a new Domain instance
      SEMVER_RE  = /\A\d+\.\d+\.\d+\z/.freeze
      CALVER_RE  = /\A\d{4}\.\d{2}\.\d{2}\.\d+\z/.freeze

      def initialize(name:, aggregates: [], paragraphs: [], policies: [], services: [], views: [],
                     workflows: [], actors: [], custom_verbs: [],
                     tenancy: nil, event_subscribers: [],
                     sagas: [], glossary_rules: [], modules: [], glossary_strict: false,
                     version: nil, world_concerns: [], description: nil)
        validate_version!(version)
        @name = name
        @version = version
        @aggregates = aggregates
        @paragraphs = paragraphs
        @policies = policies
        @services = services
        @views = views
        @workflows = workflows
        @actors = actors
        @sagas = sagas
        @glossary_rules = glossary_rules
        @glossary_strict = glossary_strict
        @modules = modules
        @custom_verbs = custom_verbs
        @tenancy = tenancy
        @event_subscribers = event_subscribers
        @world_concerns = world_concerns.map(&:to_sym)
        @description = description
      end

      # @return [String, nil] human-readable description of this domain
      attr_reader :description

      # Returns the sanitized Ruby constant name for this domain.
      # Strips non-alphanumeric characters and converts to PascalCase.
      #
      # @return [String] a valid Ruby module name (e.g., "Pizzas", "OnlineStore")
      def module_name
        Hecks::Utils.sanitize_constant(name)
      end

      # Returns the gem name for this domain's generated gem.
      # Derived by underscoring the module_name and appending "_domain".
      #
      # @return [String] the gem name (e.g., "pizzas_domain", "online_store_domain")
      def gem_name
        Hecks::Utils.underscore(module_name) + "_domain"
      end

      # Prints a human-readable tree of the domain's aggregates, commands,
      # queries, and policies to stdout. Useful for quick introspection
      # in the console or CLI.
      #
      # Each aggregate is printed with its attributes, followed by indented
      # listings of commands (with their event mappings), queries, and policies.
      # Domain-level policies are listed separately at the end.
      #
      # @return [nil]
      def describe
        lines = [name, ""]
        aggregates.each do |agg|
          attrs = agg.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
          lines << "  #{agg.name} (#{attrs})"
          agg.commands.each_with_index do |cmd, i|
            event = agg.events[i]
            cmd_attrs = cmd.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
            lines << "    #{cmd.name}(#{cmd_attrs}) -> #{event&.name}"
          end
          agg.queries.each { |q| lines << "    query: #{q.name}" }
          agg.policies.each do |pol|
            async_label = pol.async ? " [async]" : ""
            lines << "    policy: #{pol.name} (#{pol.event_name} -> #{pol.trigger_command})#{async_label}"
          end
        end

        unless policies.empty?
          lines << ""
          lines << "  Domain Policies:"
          policies.each do |pol|
            async_label = pol.async ? " [async]" : ""
            lines << "    policy: #{pol.name} (#{pol.event_name} -> #{pol.trigger_command})#{async_label}"
          end
        end

        flow_text = Hecks::FlowGenerator.new(self).generate_text
        unless flow_text == "No reactive flows found."
          lines << ""
          lines << "  Reactive Flows:"
          flow_text.each_line { |l| lines << "    #{l.rstrip}" }
        end

        puts lines.join("\n")
        nil
      end

      # Prints a glossary of all domain terms (aggregate names, attribute names,
      # command names, event names, etc.) to stdout. Delegates to Hecks::DomainGlossary.
      #
      # @return [nil]
      def glossary
        Hecks::DomainGlossary.new(self).print
      end

      # Generates Mermaid diagram markup for this domain, including both
      # structural (aggregate/value object relationships) and behavioral
      # (command/event/policy flows) diagrams.
      #
      # @return [String] Mermaid-formatted diagram markup
      def to_mermaid
        Hecks::DomainVisualizer.new(self).generate
      end

      # Prints Mermaid diagrams for this domain to stdout.
      # Convenience wrapper around +to_mermaid+ that outputs directly.
      #
      # @return [nil]
      def visualize
        Hecks::DomainVisualizer.new(self).print
      end

      # Generate plain English descriptions of the domain's reactive flows.
      #
      # @return [String] flow descriptions
      def flows
        Hecks::FlowGenerator.new(self).generate_text
      end

      # Generate a Mermaid sequence diagram of the domain's reactive flows.
      #
      # @return [String] Mermaid sequenceDiagram markup
      def flows_mermaid
        Hecks::FlowGenerator.new(self).generate_mermaid
      end

      # All reactive policies across all aggregates and domain level.
      # Eliminates Law of Demeter chain: domain.aggregates.flat_map(&:policies).select(&:reactive?)
      #
      # @return [Array<Behavior::Policy>]
      def reactive_policies
        all = aggregates.flat_map { |a| a.policies.select(&:reactive?) }
        all + policies.select(&:reactive?)
      end

      # All commands across all aggregates.
      #
      # @return [Array<Behavior::Command>]
      def all_commands
        aggregates.flat_map(&:commands)
      end

      # All events across all aggregates.
      #
      # @return [Array<Behavior::DomainEvent>]
      def all_events
        aggregates.flat_map(&:events)
      end

      # Find the aggregate that owns a command by name.
      #
      # @param command_name [String] the command name
      # @return [Aggregate, nil]
      def aggregate_for_command(command_name)
        aggregates.find { |a| a.commands.any? { |c| c.name == command_name.to_s } }
      end

      private

      def validate_version!(v)
        return if v.nil?
        return if SEMVER_RE.match?(v.to_s) || CALVER_RE.match?(v.to_s)
        raise Hecks::InvalidDomainVersion,
              "Invalid version #{v.inspect}. Must be semver (x.y.z) or CalVer (YYYY.MM.DD.N)."
      end
    end
    end
  end
end
