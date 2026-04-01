
module Hecks
  class Workshop
    # Hecks::Workshop::PlayMode
    #
    # Session mixin for play-mode: executing commands against a live compiled
    # domain and inspecting events. Part of the Session layer -- delegates to
    # Playground for actual execution.
    #
    # Play mode compiles the current domain definition into a temporary gem,
    # boots a Runtime with in-memory adapters, and lets you execute commands
    # and query repositories. All events are captured and can be inspected.
    #
    # Switching between modes:
    # - +play!+ validates the domain, compiles it, and enters play mode
    # - +sketch!+ tears down the playground and returns to sketch mode
    #
    #   workshop.play!
    #   Pizza.create_pizza(name: "Margherita")
    #   workshop.events
    #   workshop.history
    #   workshop.sketch!   # back to sketch mode
    #
    module PlayMode
      include HecksTemplating::NamingHelpers
      # Switch to play mode by compiling the domain and booting a live runtime.
      #
      # Validates the domain first; if invalid, prints errors and stays in
      # sketch mode. On success, creates a Playground, switches mode to :play,
      # and prints usage hints showing example commands for the first aggregate.
      #
      # @return [Session] self
      def play!
        domain = to_domain
        valid, errors = Hecks.validate(domain)

        unless valid
          puts "Can't enter play mode - domain is invalid:"
          errors.each { |e| puts "  - #{e}" }
          return self
        end

        @playground = Playground.new(domain)
        @mode = :play
        first_agg = domain.aggregates.first
        example_cmd = first_agg&.commands&.first
        if first_agg && example_cmd
          agg_name = first_agg.name
          puts "Entering play mode"
          puts ""
          puts "  #{agg_name}.create(...)   # run a command"
          puts "  #{agg_name}.all           # list all"
          puts "  #{agg_name}.find(id)      # find by id"
          puts "  events                    # event log"
          puts "  history                   # numbered timeline"
          puts "  reset!                    # clear all data"
          puts "  sketch!                   # back to sketch mode"
        else
          puts "Entering play mode"
          puts ""
          puts "  browse                                  # see what's available"
          puts "  sketch!                                 # back to sketch mode"
        end
        puts ""
        self
      end

      # Switch back to sketch mode, tearing down the playground.
      #
      # Sets mode to :sketch and nils out the playground reference,
      # allowing the compiled domain module to be garbage collected.
      #
      # @return [Session] self
      def sketch!
        @mode = :sketch
        @playground = nil
        puts "Back to sketch mode"
        self
      end

      # Execute a command by name against the live playground.
      #
      # Auto-enters play mode if not already in it. Delegates to
      # Playground#execute which resolves the aggregate, translates the
      # command name to a method call, and captures the emitted event.
      #
      # @param command_name [String] the command class name (e.g. "CreatePizza")
      # @param attrs [Hash] keyword arguments for the command
      # @return [Object] the result of the command execution
      def execute(command_name, **attrs)
        play! unless play?
        @playground.execute(command_name, **attrs)
      end

      # Return the most recent event captured during play mode.
      #
      # @return [Object, nil] the last event or nil if no events yet
      def last_event
        return nil unless play? && @playground
        @playground.events.last
      end

      # Return all events captured during play mode.
      #
      # @return [Array] list of event objects recorded by the playground
      # @raise [RuntimeError] if not in play mode
      def events
        ensure_play_mode!
        @playground.events
      end

      # Return events of a specific type by class name.
      #
      # @param type_name [String] the short event class name (e.g. "CreatedPizza")
      # @return [Array] matching event objects
      # @raise [RuntimeError] if not in play mode
      def events_of(type_name)
        ensure_play_mode!
        @playground.events_of(type_name)
      end

      # List all available commands in the compiled domain.
      #
      # @return [Array<String>] command descriptions with signatures and event names
      # @raise [RuntimeError] if not in play mode
      def commands
        ensure_play_mode!
        @playground.commands
      end

      # Print a numbered history of all events that have occurred.
      #
      # @return [nil]
      # @raise [RuntimeError] if not in play mode
      def history
        ensure_play_mode!
        @playground.history
      end

      # Clear all events and repository data in the playground.
      #
      # @return [void]
      # @raise [RuntimeError] if not in play mode
      def reset!
        ensure_play_mode!
        @playground.reset!
      end

      # Apply an extension to the live runtime without rebooting.
      #
      #   play!
      #   extend :logging
      #   extend :sqlite
      #
      # @param name [Symbol] the extension name
      # @return [Session] self
      # @raise [RuntimeError] if not in play mode
      def extend(name, **kwargs)
        ensure_play_mode!
        @playground.extend(name, **kwargs)
        self
      end

      private

      # Start the web explorer server in a background thread.
      #
      # Enters play mode first if not already in it. Requires the static
      # server gem and starts it on the given port.
      #
      # @param port [Integer] the port to serve on (default: 9292)
      # @return [Session] self
      def serve!(port: 9292)
        play! unless play?
        mod_name = domain_module_name(@name)
        if Object.const_defined?(mod_name)
          mod = Object.const_get(mod_name)
          if mod.respond_to?(:serve)
            Thread.new { mod.serve(port: port) }
            puts "Serving #{@name} on http://localhost:#{port}"
          else
            puts "#{mod_name} does not support serve — build static first"
          end
        else
          puts "#{mod_name} not found"
        end
        self
      end

      # Guard that raises unless the workshop is in play mode.
      #
      # @raise [RuntimeError] if not in play mode
      # @return [void]
      def ensure_play_mode!
        raise "Not in play mode. Call workshop.play! first." unless play?
      end
    end
  end
end
