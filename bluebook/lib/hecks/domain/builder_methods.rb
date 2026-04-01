
module Hecks
  # Hecks::DomainBuilderMethods
  #
  # DSL entry points for defining, validating, and previewing domains.
  # This module is extended onto the top-level Hecks module to provide
  # the primary API for domain construction. It wraps the DSL builders,
  # validator, and code generators behind simple top-level methods.
  #
  # These methods are the main interface for creating and inspecting
  # domain models before they are compiled or loaded.
  #
  #   Hecks.domain("Pizzas") { ... }
  #   Hecks.validate(domain)
  #   Hecks.preview(domain, "Pizza")
  #   Hecks.workshop("Pizzas")
  #
  module DomainBuilderMethods
    include HecksTemplating::NamingHelpers
    # Define a new domain using the Hecks DSL. Evaluates the given block
    # inside a DomainBuilder, which collects aggregate definitions, policies,
    # workflows, views, and services. The resulting Domain object is stored
    # as +Hecks.last_domain+ for snapshot tooling.
    #
    # @param name [String] the human-readable domain name (e.g., "Pizzas")
    # @param block [Proc] DSL block evaluated inside DSL::DomainBuilder
    # @return [Hecks::DomainModel::Domain] the fully built domain IR object
    def domain(name, version: nil, &block)
      model(name, version: version, grammar: :bluebook, &block)
    end

    # Generic entry point — delegates to whichever grammar's builder.
    #   Hecks.model "SpaceGame", grammar: :game_book do ... end
    #   Hecks.model "Pizzas" do ... end  # defaults to :bluebook
    def model(name, grammar: :bluebook, version: nil, &block)
      g = Hecks.grammar(grammar)
      builder_class = g&.builder || DSL::DomainBuilder
      builder = builder_class.new(name, version: version)
      builder.instance_eval(&block)
      result = builder.build
      result.source_path = caller_locations(1, 1).first.absolute_path if result.respond_to?(:source_path=)
      Hecks.last_domain = result
      result
    end

    # Define hexagonal architecture wiring for a domain. Evaluates the given
    # block inside a HecksagonBuilder, which collects gates, adapter config,
    # extensions, and cross-domain subscriptions.
    #
    # @param block [Proc] DSL block evaluated inside Hecksagon::DSL::HecksagonBuilder
    # @return [Hecksagon::Structure::Hecksagon] the fully built Hecksagon IR object
    def hecksagon(&block)
      builder = Hecksagon::DSL::HecksagonBuilder.new
      builder.instance_eval(&block)
      result = builder.build
      Hecks.last_hecksagon = result
      result
    end

    # Create a new interactive session for the named domain. Sessions provide
    # a REPL-like environment for exploring aggregates, running commands, and
    # querying domain state.
    #
    # @param name [String] the domain name to load into the session
    # @return [Hecks::Workshop] a new session instance bound to the domain
    def workshop(name)
      Workshop.new(name)
    end

    # Validate a domain model against all registered validation rules.
    # Returns a tuple of validity and any error messages. Does not raise
    # on invalid domains -- callers decide how to handle errors.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain to validate
    # @return [Array(Boolean, Array<String>)] [valid?, error_messages]
    def validate(domain)
      validator = Validator.new(domain)
      [validator.valid?, validator.errors]
    end

    # Generate Ruby source code for a single aggregate without writing to disk.
    # Useful for previewing what +build+ would produce for a specific aggregate.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain containing the aggregate
    # @param aggregate_name [String] the name of the aggregate to preview (e.g., "Pizza")
    # @return [String] generated Ruby source code for the aggregate class
    # @raise [RuntimeError] if the named aggregate does not exist in the domain
    def preview(domain, aggregate_name)
      mod = domain_module_name(domain.name)
      agg = domain.aggregates.find { |a| a.name == aggregate_name }
      raise "Unknown aggregate: #{aggregate_name}" unless agg
      Generators::Domain::AggregateGenerator.new(agg, domain_module: mod).generate
    end
  end
end
