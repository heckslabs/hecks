# frozen_string_literal: true

require_relative "../red_main"

module Hecks
  module Adapters
    class SettingsReading
      # The `red main stop` row of `hecks config`: whether a red main refuses every push that fixes no
      # red row, how long the `gh` answer is kept, and whether the Hecks world or the default says so.
      module RedMainStop
        # @param directory [String] the domain directory
        # @return [Array(String, String, String)] the row's name, value and source
        def red_main_stop(directory)
          declared = Hecks.describe(directory).registry.world("Hecks")&.for_verb(RedMain::VERB)
          return ["red main stop", "off", "default"] unless declared

          minutes = declared[:cache_minutes] || RedMain::CACHE_MINUTES
          ["red main stop", "on: only a fix for a red row is pushed while main CI is red; gh answer kept #{minutes} minutes", "world"]
        rescue StandardError => e
          ["red main stop", "could not be read", first_line(e.message)]
        end
      end
    end
  end
end
