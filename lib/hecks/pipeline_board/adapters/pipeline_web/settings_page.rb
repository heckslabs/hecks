# frozen_string_literal: true

require "hecks/hecks/adapters/dial_turning"
require "hecks/hecks/adapters/moving_cap"
require_relative "in_force"
require_relative "signalbox_marks"

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
        #   set it (`turned`), its `kind`, its bounds, the `context` it governs and what it `says`,
        #   and its `force` (whether it is in force now, standing by or without effect, and why);
        #   `cap:` where the moving work cap stands ({MovingCap.standing}), nil while it is fixed;
        #   `governs:` the side that governs load, admission, protection and reaping; `signal:`
        #   Signalbox's posted signal while current; `marks:` Signalbox's marks, read only
        def settings
          registry = @wiring.registry
          dials = DialTurning::Standing.rows(registry)
          reading = InForce.reading(registry)
          { dials: InForce.rows(dials, reading), cap: reading[:moving], governs: InForce.governs(dials, reading),
            signal: reading[:posted], marks: SignalboxMarks.of(registry, cores: reading[:posted]&.fetch(:cores, nil)) }
        end
      end
    end

    # Reopened here so the Settings page's readers sit beside the page they read.
    class PipelineWeb
      include PipelineBoard::SettingsPage
    end
  end
end
