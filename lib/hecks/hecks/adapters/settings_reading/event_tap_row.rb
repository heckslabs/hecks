# frozen_string_literal: true

module Hecks
  module Adapters
    class SettingsReading
      # The `event tap` row of `hecks config`: where the runtime's event tap writes, and whether
      # the `HECKS_EVENT_TAP` variable, the world or neither says.
      module EventTapRow
        # @param directory [String] the domain directory
        # @return [Array(String, String, String)] the row's name, value and source
        def event_tap(directory)
          declared = declared_event_log(directory)
          return ["event tap", "none declared", "default"] if declared.empty?
          return ["event tap", "off", "world"] if declared[:path].to_s.empty?

          override = Assembly.event_tap_override
          source = override ? "variable #{Assembly::EVENT_TAP_VARIABLE}" : "world"
          ["event tap", Runtime::EventTap.path_for(declared, override) || "off", source]
        rescue StandardError => e
          ["event tap", "could not be read", first_line(e.message)]
        end

        private

        # The Hecks world's `event_log` settings, empty when it declares none.
        def declared_event_log(directory)
          world = Hecks.describe(directory).registry.world("Hecks")
          world&.for_verb(Runtime::EventTap::VERB).to_h
        end
      end
    end
  end
end
