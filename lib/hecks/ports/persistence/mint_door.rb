require_relative "../../runtime/errors"

module Hecks
  module Ports
    module Persistence
      # The commands whose own record an unminted boot may write, as a persistence binding names
      # them: `persisted_by("PostgresEra") { mints_era "Maintenance.MintEra" }` in a world. This is
      # where the allowance lives; the `mints_era true` a command can still carry is read as a
      # fallback, and the two must agree.
      #
      # A name is `Aggregate.Command`. The world may give one name or a list.
      module MintDoor
        module_function

        # @param settings [Hash{Symbol, String => Object}] a persistence binding's settings
        # @return [Array<String>] the `Aggregate.Command` names the binding declares, else `[]`
        def names(settings)
          Array(settings.transform_keys(&:to_sym)[:mints_era]).map(&:to_s)
        end

        # @param settings [Hash] a persistence binding's settings
        # @param aggregate_name [String] the aggregate the command belongs to
        # @param command_name [String] the command
        # @return [Boolean] true when the binding names `aggregate_name.command_name`
        def declared?(settings, aggregate_name, command_name)
          names(settings).include?("#{aggregate_name}.#{command_name}")
        end

        # Checks the binding against the bluebook it serves, before anything is written.
        #
        # A binding that names no command leaves the bluebook word alone. One that does must name
        # only commands the bluebook declares, and every command the bluebook flags with
        # `mints_era true` must be among them, so the two never disagree about who may write.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook the binding serves
        # @param settings [Hash] the binding's settings
        # @return [void]
        # @raise [Runtime::WiringError] naming the command when the two disagree
        def check!(bluebook, settings)
          declared = names(settings)
          return if declared.empty?

          known = commands_of(bluebook)
          unknown = declared - known.keys
          raise_unknown!(bluebook, unknown, known) unless unknown.empty?

          unnamed = known.select { |name, flagged| flagged && !declared.include?(name) }.keys
          raise_unnamed!(bluebook, unnamed, declared) unless unnamed.empty?
        end

        # @return [Hash{String => Boolean}] `Aggregate.Command` => whether it says `mints_era true`
        def commands_of(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            aggregate.commands.map { |command| ["#{aggregate.hecks_name}.#{command.hecks_name}", command.mints_era?] }
          end.to_h
        end

        def raise_unknown!(bluebook, unknown, known)
          raise Runtime::WiringError,
                "the world's mints_era names #{unknown.join(", ")}, but #{bluebook.name} declares no such command " \
                "(its commands: #{known.keys.join(", ")}). A name that matches nothing would let no write through " \
                "an unminted boot, so the boot refuses."
        end

        def raise_unnamed!(bluebook, unnamed, declared)
          raise Runtime::WiringError,
                "#{unnamed.join(", ")} declares `mints_era true` in #{bluebook.name}, but the world's mints_era " \
                "(#{declared.join(", ")}) does not name it. Name it in the world, or remove the word from the " \
                "command: the two must agree."
        end
      end
    end
  end
end
