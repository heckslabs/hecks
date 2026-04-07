require "fileutils"

# Load workshop implementation files from the Workshop chapter definition.
require "hecks/chapters/workshop"
Hecks::Chapters.load_chapter(
  Hecks::Chapters::Workshop,
  base_dir: __dir__
)

module Hecks
  # Hecks::Workshop
  #
  # Interactive domain-building workshop for REPL-driven development. Supports
  # two modes: "sketch" (define aggregates, commands, policies) and "play"
  # (execute commands and inspect events against a live compiled domain).
  #
  #   workshop = Hecks.workshop("Pizzas")
  #   workshop.aggregate("Pizza") { attribute :name, String }
  #   workshop.validate
  #   workshop.build
  #   workshop.play!
  #
  class Workshop
    include HecksTemplating::NamingHelpers
    include BuildActions
    include PlayMode
    include Presenter
    include DeepInspect
    include SystemBrowser
    include PersistentImage
    include BluebookMode

    attr_reader :name, :playground, :aggregate_builders

    # Initialize a new workshop for the given domain name.
    #
    # Sets up empty aggregate builders, handles, custom verbs, and defaults
    # to sketch mode with no playground.
    #
    # @param name [String] the domain name (e.g. "Pizzas", "Accounting")
    def initialize(name)
      @name = name
      @aggregate_builders = {}
      @handles = {}
      @service_builders = []
      @custom_verbs = []
      @active_hecks = false
      @mode = :sketch
      @playground = nil
    end

    # Return the current workshop mode.
    #
    # @return [Symbol] either +:sketch+ or +:play+
    def mode
      @mode
    end

    # Check whether the workshop is in sketch (build) mode.
    #
    # @return [Boolean] true when the workshop is in sketch mode
    def sketch?
      @mode == :sketch
    end

    # Check whether the workshop is in play (runtime) mode.
    #
    # @return [Boolean] true when the workshop is in play mode
    def play?
      @mode == :play
    end

    # Get or create an aggregate by name, returning an interactive handle.
    #
    # If a block is given, it is evaluated in the context of the underlying
    # AggregateBuilder (so +attribute+, +command+, +policy+, etc. are available).
    # The method always returns an AggregateHandle that can be used for
    # incremental building (e.g. +pizza.attr :name, String+).
    #
    # @param name [String] the aggregate name (will be sanitized to a valid constant)
    # @yield optional block evaluated on the AggregateBuilder for batch definition
    # @return [AggregateHandle] interactive handle for the aggregate
    def aggregate(name, &block)
      name = normalize_name(name)
      builder = @aggregate_builders[name] ||= DSL::AggregateBuilder.new(name)
      builder.instance_eval(&block) if block

      handle = @handles[name] ||= AggregateHandle.new(name, builder, domain_module: domain_module_name(@name), workshop: self)

      if block
        agg = builder.build
        puts "#{name} (#{aggregate_summary(agg)})"
      end

      handle
    end

    # Define a domain service that orchestrates commands across aggregates.
    #
    # Services are domain-level operations that coordinate multiple aggregates.
    # The block is evaluated in the context of a ServiceBuilder.
    #
    # @param name [String] the service name (e.g. "TransferMoney")
    # @yield block evaluated in the context of ServiceBuilder
    # @return [void]
    def service(name, &block)
      builder = DSL::ServiceBuilder.new(name)
      builder.instance_eval(&block) if block
      @service_builders << builder.build
      puts "Service #{name} added"
    end

    # Build and return a Domain structure from the current aggregate definitions.
    #
    # Constructs a DomainModel::Structure::Domain by building each aggregate
    # from its builder, collecting them along with any custom verbs.
    #
    # @return [DomainModel::Structure::Domain] the fully assembled domain object
    def to_domain
      aggregates = @aggregate_builders.values.map(&:build)
      DomainModel::Structure::Domain.new(
        name: @name, aggregates: aggregates,
        services: @service_builders, custom_verbs: @custom_verbs
      )
    end

    # Compile the domain and activate ActiveHecks (Rails persistence layer).
    #
    # Loads the domain into memory, then attempts to require the active_hecks gem
    # and activate it. Prints a warning if the gem is not installed.
    #
    # @return [Module] the loaded domain module, or nil if active_hecks is unavailable
    def active_hecks!
      @active_hecks = true
      domain = to_domain
      mod = Hecks.load_domain(domain, force: true, skip_validation: true)
      begin
        require "active_hecks"
      rescue LoadError
        puts "active_hecks gem not installed. Add it to your Gemfile."
        return mod
      end
      ActiveHecks.activate(mod, domain: domain)
      puts "ActiveHecks loaded for #{domain_module_name(domain.name)}"
      mod
    end

    # Check if ActiveHecks has been activated for this workshop.
    #
    # @return [Boolean] true if +active_hecks!+ has been called
    def active_hecks?
      @active_hecks
    end

    # Register a custom verb for use in command naming.
    #
    # Custom verbs extend the set of recognized action words that can appear
    # in command names (e.g. "Bake", "Ferment"). Duplicates are ignored.
    #
    # @param word [String, Symbol] the verb to register
    # @return [Session] self, for chaining
    def add_verb(word)
      @custom_verbs << word.to_s unless @custom_verbs.include?(word.to_s)
      self
    end

    # Return the list of aggregate names defined in this workshop.
    #
    # @return [Array<String>] aggregate names (sanitized constant form)
    def aggregates
      @aggregate_builders.keys
    end

    # Remove an aggregate by name from the workshop.
    #
    # Deletes both the builder and its handle. Prints confirmation or
    # an error if no aggregate with that name exists.
    #
    # @param aggregate_name [String] the name of the aggregate to remove
    # @return [Session] self, for chaining
    def remove(aggregate_name)
      if @aggregate_builders.delete(aggregate_name)
        @handles.delete(aggregate_name)
        puts "Removed #{aggregate_name}"
      else
        puts "No aggregate named #{aggregate_name}"
      end
      self
    end

    # Promote an aggregate into its own standalone domain.
    #
    # Extracts the named aggregate from this workshop, creates a new domain
    # containing just that aggregate, writes it to a file, and removes it
    # from the current workshop. The new domain can be wired back via
    # `extend NewDomain` for cross-domain event listening.
    #
    #   workshop.promote("Comments")
    #   # => Wrote comments_domain.rb (1 aggregate, 2 commands)
    #   # => Comments removed from Blog
    #
    # @param aggregate_name [String] the aggregate to promote
    # @param output_dir [String] directory to write the new domain file (default: ".")
    # @return [String] path to the new domain file
    # @raise [RuntimeError] if the aggregate doesn't exist
    def promote(aggregate_name)
      name = normalize_name(aggregate_name)
      builder = @aggregate_builders[name]
      raise "No aggregate named #{name}" unless builder

      # Build a standalone domain from this aggregate
      agg = builder.build
      new_domain = DomainModel::Structure::Domain.new(
        name: name, aggregates: [agg], custom_verbs: []
      )

      # Serialize and write
      dsl = DslSerializer.new(new_domain).serialize
      file_name = "#{domain_snake_name(name)}_domain.rb"
      File.write(file_name, dsl)

      # Remove from current workshop
      @aggregate_builders.delete(name)
      @handles.delete(name)

      puts "Wrote #{file_name} (#{agg.attributes.size} attributes, #{agg.commands.size} commands)"
      puts "#{name} removed from #{@name}"
      file_name
    end

    private

    # Normalize a user-provided name into a valid Ruby constant string.
    #
    # @param name [String] the raw name
    # @return [String] sanitized constant name
    def normalize_name(name)
      domain_constant_name(name)
    end

    # Build a human-readable summary string for an aggregate.
    #
    # Lists counts of attributes, value objects, entities, commands, and
    # policies. Returns "empty" if the aggregate has none of these.
    #
    # @param agg [DomainModel::Structure::Aggregate] the built aggregate
    # @return [String] summary like "3 attributes, 2 commands"
    def aggregate_summary(agg)
      parts = []
      parts << "#{agg.attributes.size} attributes" unless agg.attributes.empty?
      parts << "#{agg.value_objects.size} value objects" unless agg.value_objects.empty?
      parts << "#{agg.entities.size} entities" unless agg.entities.empty?
      parts << "#{agg.commands.size} commands" unless agg.commands.empty?
      parts << "#{agg.policies.size} policies" unless agg.policies.empty?
      parts.empty? ? "empty" : parts.join(", ")
    end
  end
end
