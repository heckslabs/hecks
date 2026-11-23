require_relative "admission"
require_relative "clock/runner"
require_relative "clock/launch_files"

module Hecks
  module Adapters
    module Driving
      # The clock driving adapter (ADR 0184): runs a clock a domain's hecksagon declares, one
      # process per clock, and dispatches its command through the storehouse with the source
      # `clock`, so the command's givens, role and governance apply as for any caller.
      module Clock
        # The trace summary of a firing.
        SUMMARY = "clock %<clock>s fired for %<due>s".freeze

        module_function

        # Every clock the booted domain's hecksagons declare, with the domain declaring each.
        #
        # @param runtime [Runtime::Registry] a booted domain
        # @return [Array(String, Bluebook::Clock)] each clock's domain and the clock
        def declared(runtime)
          registry = runtime.registry
          registry.hecksagons.each_value.flat_map { |hecksagon| domain_clocks(hecksagon) }
        end

        # @param hecksagon [Bluebook::Hecksagon] one domain's wiring
        # @return [Array(String, Bluebook::Clock)] its clocks, each beside the domain's name
        def domain_clocks(hecksagon) = hecksagon.clocks.map { |clock| [hecksagon.domain, clock] }

        # @param runtime [Runtime::Registry] a booted domain
        # @param name [String] a clock's name
        # @return [Array(String, Bluebook::Clock)] its domain and the clock
        # @raise [Runtime::NotFound] when the domain declares no clock of that name
        def find(runtime, name)
          clocks = declared(runtime)
          found = clocks.find { |_, clock| clock.name == name.to_s }
          return found if found

          names = clocks.map { |_, clock| clock.name }
          raise Runtime::NotFound,
                "no clock named #{name.inspect}; the domain declares #{names.empty? ? "none" : names.join(", ")}"
        end

        # Builds the runner for one clock of a booted domain, dispatching through the storehouse.
        #
        # @param runtime [Runtime::Registry] a booted domain
        # @param name [String] the clock's name
        # @param options [Hash] `time:`, `lock:` and `log:`, as `Runner` takes them
        # @return [Runner] the runner
        # @raise [Admission::Refused] when the domain does not admit the Clock adapter
        def runner(runtime, name, **options)
          Admission.admit!(runtime.registry, "Clock")
          domain, clock = find(runtime, name)
          lock = options.delete(:lock) || FiringLock.for(runtime.registry, clock, domain)
          Runner.new(clock: clock, fire: dispatcher(runtime, clock), lock: lock, **options)
        end

        # @param runtime [Runtime::Registry] a booted domain
        # @param clock [Bluebook::Clock] the clock
        # @return [Proc] dispatches one firing's command, answering the storehouse's outcome
        def dispatcher(runtime, clock)
          lambda do |firing|
            Storehouse.dispatch(runtime: runtime, command: storehouse_name(clock), args: firing.arguments,
                                summary: format(SUMMARY, clock: clock.name, due: firing),
                                source: "clock", role: clock.role)
          end
        end

        # @param clock [Bluebook::Clock] the clock
        # @return [String] the command as the storehouse's alias table spells it, `loan.open_loan`
        def storehouse_name(clock) = "#{Naming.snake(clock.aggregate_name)}.#{Naming.snake(clock.command_name)}"

        # One line per declared clock: its name, its trigger and when it next fires.
        #
        # @param runtime [Runtime::Registry] a booted domain
        # @param now [Integer] Unix seconds
        # @return [String] the lines, or a sentence saying there are no clocks
        def upcoming(runtime, now)
          lines = declared(runtime).map { |_, clock| upcoming_line(clock, now) }
          lines.empty? ? "no clocks declared" : lines.join("\n")
        end

        # @return [String] one clock's line for `upcoming`
        def upcoming_line(clock, now)
          due = Schedule.for(clock).next_after(now)
          trigger = [clock.trigger, clock.expression.inspect, clock.zone && "zone #{clock.zone}"].compact.join(" ")
          "#{clock.name}  #{trigger}  -> #{clock.command}  next: #{due ? Firing.new(clock, due) : "never"}"
        end
      end
    end
  end
end
