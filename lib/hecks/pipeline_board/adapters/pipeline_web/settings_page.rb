# frozen_string_literal: true

require "hecks/hecks/adapters/dial_turning"

module Hecks
  module Adapters
    module PipelineBoard
      # The Settings page, answered by the board's web adapter at `/settings`: the limits this
      # machine runs the pipeline under, each with what it stands at and the bounds it is set
      # inside. The page sets one through the board's `turn` step; reading it changes nothing.
      module SettingsPage
        # The page file.
        PATH = File.expand_path("settings.html", __dir__)

        # @return [String] the Settings page
        def settings_page = File.read(PATH)

        # @return [Hash] `dials:` each setting a turn may set, with its `value` now, whether a turn
        #   set it (`turned`), its `kind`, its bounds, the `context` it governs and what it `says`
        def settings = { dials: DialTurning::Standing.rows(@wiring.registry) }
      end
    end

    # Reopened here so the Settings page's readers sit beside the page they read.
    class PipelineWeb
      include PipelineBoard::SettingsPage
    end
  end
end
