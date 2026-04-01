require_relative "playground/gem_bootstrap"
require_relative "playground/runtime_resolver"

module Hecks
  class Workshop
    # Hecks::Workshop::Playground
    #
    # Live execution sandbox that compiles a domain model into real Ruby classes,
    # boots a full Runtime with memory adapters, and lets you execute commands
    # with real persistence. Used by Session's "play" mode for rapid prototyping.
    #
    # Generates a temp gem, loads it, then creates a Runtime that wires
    # persistence, commands, queries, and the event bus. Aggregates are
    # persisted in memory -- find, all, count, where all work.
    #
    # The Playground intercepts the event bus's +publish+ method to capture every
    # emitted event into an internal list for inspection via +events+, +events_of+,
    # and +history+.
    #
    # Mixins:
    #   GemBootstrap    -- temp gem compilation and loading (compile!)
    #   RuntimeResolver -- command/event class resolution and policy checking
    #
    #   playground = Hecks::Workshop::Playground.new(domain)
    #   playground.execute("CreatePizza", name: "Margherita")
    #   Pizza.find(id)         # works -- persisted in memory
    #   Pizza.all              # works
    #   playground.events      # => [#<CreatedPizza ...>]
    #   playground.reset!      # clears events and repositories
    #
    class Playground
      include HecksTemplating::NamingHelpers
    include GemBootstrap
    include RuntimeResolver

    attr_reader :events, :runtime

    # Create and boot a new playground for the given domain.
    #
    # Compiles the domain into a temporary gem, loads it, collects policy
    # definitions, and boots a Runtime with memory adapters and an
    # event-capturing event bus.
    #
    # @param domain [DomainModel::Structure::Domain] the domain to compile and run
    def initialize(domain)
      @domain = domain
      @mod_name = domain_module_name(domain.name)
      @events = []
      @policies = collect_policies
      compile!
      boot_runtime!
    end

    # Execute a command by name against the live runtime.
    #
    # Resolves the aggregate that owns the command, translates the command
    # name to a method call on the aggregate class, and invokes it. After
    # execution, prints the command name, emitted event details, and any
    # triggered policies.
    #
    # @param command_name [String] the command class name (e.g. "CreatePizza")
    # @param attrs [Hash] keyword arguments to pass to the command
    # @return [Object] the result of the command execution (typically the aggregate)
    # @raise [RuntimeError] if the command name is not found in any aggregate
    def execute(command_name, **attrs)
      agg_def = @domain.aggregates.find do |a|
        a.commands.any? { |c| c.name == command_name.to_s }
      end
      unless agg_def
        available = @domain.aggregates.flat_map { |a| a.commands.map(&:name) }
        raise "Unknown command: #{command_name}. Available: #{available.join(', ')}"
      end

      mod = Object.const_get(@mod_name)
      agg_class = mod.const_get(domain_constant_name(agg_def.name))
      agg_snake = domain_snake_name(agg_def.name)
      method_name = domain_snake_name(command_name).sub(/_#{agg_snake}$/, "").to_sym

      result = agg_class.send(method_name, **attrs)

      event = @events.last
      if event
        event_name = Hecks::Utils.const_short_name(event)
        puts "Command: #{command_name}"
        puts "  Event: #{event_name}"
        attrs.each { |k, v| puts "    #{k}: #{v.inspect}" }
        puts "    occurred_at: #{event.occurred_at}"

        triggered = check_policies(event)
        triggered.each do |policy|
          puts "  Policy: #{policy.name} -> #{policy.trigger_command}"
        end
      end

      result
    end

    # List all available commands with their signatures and event mappings.
    #
    # @return [Array<String>] formatted command descriptions, e.g.
    #   ["CreatePizza(name: String) -> CreatedPizza"]
    def commands
      @domain.aggregates.flat_map do |agg|
        agg.commands.map do |cmd|
          event = agg.events.find { |e| e.name == cmd.inferred_event_name }
          attrs = cmd.attributes.map { |a| "#{a.name}: #{a.type}" }.join(", ")
          "#{cmd.name}(#{attrs}) -> #{event&.name}"
        end
      end
    end

    # Filter captured events by their short class name.
    #
    # @param type_name [String] the event class name (e.g. "CreatedPizza")
    # @return [Array] events whose class name matches
    def events_of(type_name)
      @events.select { |e| Hecks::Utils.const_short_name(e) == type_name }
    end

    # Clear all captured events and repository data.
    #
    # Empties the events list and calls +clear+ on each aggregate's
    # repository (memory adapter supports this).
    #
    # @return [void]
    def reset!
      @events.clear
      @domain.aggregates.each do |agg|
        repo = @runtime[agg.name]
        repo.clear if repo.respond_to?(:clear)
      end
      puts "Cleared all events and data"
    end

    # Print a numbered timeline of all captured events.
    #
    # Each line shows the event index, class name, and timestamp.
    #
    # @return [nil]
    def history
      if @events.empty?
        puts "No events yet"
        return
      end

      @events.each_with_index do |event, i|
        name = Hecks::Utils.const_short_name(event)
        puts "#{i + 1}. #{name} at #{event.occurred_at}"
      end
      nil
    end

    # Apply an extension to the live playground runtime.
    #
    # @param name [Symbol] the extension name (e.g. :logging, :sqlite)
    # @return [void]
    def extend(name, **kwargs)
      @runtime.extend(name, **kwargs)
    end

    # Return a compact string representation of the playground.
    #
    # @return [String] e.g. '#<Hecks::Workshop::Playground "Pizzas" (3 events)>'
    def inspect
      "#<Hecks::Workshop::Playground \"#{@domain.name}\" (#{@events.size} events)>"
    end

    private

    # Boot a full Runtime with memory adapters, capturing all events.
    #
    # Creates an EventBus and wraps its +publish+ method to append every
    # published event to the playground's internal events list. Then creates
    # a Runtime using this bus, which wires up repositories, commands, and
    # queries for all aggregates.
    #
    # @return [void]
    def boot_runtime!
      playground_events = @events
      bus = EventBus.new

      # Intercept publish to capture every event into playground's list
      original_publish = bus.method(:publish)
      bus.define_singleton_method(:publish) do |event|
        original_publish.call(event)
        playground_events << event
      end

      @runtime = Runtime.new(@domain, event_bus: bus)
    end
  end
  end
end
