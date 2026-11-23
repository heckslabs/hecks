module Hecks
  module Runtime
    class Registry
      # The checks a hecksagon's clocks owe at boot (ADR 0184): the hecksagon admits the Clock
      # adapter by name, each clock's name is its own, and each dispatches a command its bluebook
      # declares with arguments a firing can supply. A trigger is read by the Clock adapter, which
      # refuses one it cannot read when it runs. Mixed into {Verification}.
      module ClockRules
        private

        def refuse_unadmitted_clocks!(hecksagon)
          return if hecksagon.clocks.empty?

          refuse_clock_admission!(hecksagon)
          refuse_twin_clocks!(hecksagon)
          hecksagon.clocks.each { |clock| refuse_malformed_clock!(hecksagon, clock) }
        end

        def refuse_clock_admission!(hecksagon)
          return if hecksagon.driving.include?("Clock")

          names = hecksagon.clocks.map { |clock| clock.name.inspect }.join(", ")
          raise WiringError, "#{hecksagon.domain} declares clock #{names} but is not driven_by \"Clock\" — " \
                             "add driven_by \"Clock\" to its hecksagon to admit it"
        end

        def refuse_twin_clocks!(hecksagon)
          names = hecksagon.clocks.map(&:name)
          twin = names.find { |name| names.count(name) > 1 }
          return unless twin

          raise WiringError, "#{hecksagon.domain} declares clock #{twin.inspect} more than once"
        end

        def refuse_malformed_clock!(hecksagon, clock)
          refuse_unknown_firing_values!(clock)
          refuse_unknown_clock_command!(hecksagon, clock)
        rescue ArgumentError => e
          raise WiringError, "#{hecksagon.domain}'s clock #{clock.name.inspect}: #{e.message}"
        end

        def refuse_unknown_firing_values!(clock)
          known = Bluebook::Clock::FIRING_VALUES
          unknown = clock.arguments.values.grep(Symbol) - known
          return if unknown.empty?

          raise ArgumentError, "with names #{unknown.first.inspect}, which a firing does not know — " \
                               "it knows #{known.map(&:inspect).join(", ")}"
        end

        def refuse_unknown_clock_command!(hecksagon, clock)
          aggregate = bluebook(hecksagon.domain)&.aggregate(clock.aggregate_name)
          return if aggregate&.commands&.any? { |command| command.hecks_name == clock.command_name }

          raise ArgumentError, "dispatch #{clock.command.inspect} names no command #{hecksagon.domain} declares"
        end
      end
    end
  end
end
