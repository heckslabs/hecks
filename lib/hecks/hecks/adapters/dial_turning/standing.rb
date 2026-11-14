# frozen_string_literal: true

module Hecks
  module Adapters
    class DialTurning
      # What each turnable setting stands at now: the value the booted worlds hold, with the
      # checkout's `turned.local.world` read over it, since a process booted before a turn still
      # holds the value from before it.
      module Standing
        module_function

        # @param registry [Runtime::Registry, nil] a booted registry holding the Hecks bluebook
        # @param directory [String] where the turned file is
        # @return [Array<Hash>] each `Turnable` row with its `value` now and whether a turn set it
        #   (`turned`); the value is nil when no world declares the setting
        def rows(registry, directory: DialTurning.directory)
          rows = Turnables.from_registry(registry)
          return rows if rows.empty?

          turned = TurnedFile.new(directory).values
          rows.map { |row| row.merge(standing(row, registry, turned)) }
        end

        def standing(row, registry, turned)
          verb, key = row[:setting].split(".")
          set = turned.dig([row[:world], verb], key)
          booted = registry&.world(row[:world])&.for_verb(verb).to_h[key.to_sym]
          { value: set.nil? ? booted : set, turned: !set.nil? }
        end
      end
    end
  end
end
