# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module InForce
        # The words for each switch of the Tickets world, off and on: a switch is the thing that
        # decides which side governs, so its row says what it has decided.
        module Switches
          WORDS = {
            "admission.signalbox"                => ["Off: the work cap holds.", "On: Signalbox admits each coder by headroom."],
            "protection.signalbox"               => ["Off: the boot fuse holds as before.",
                                                     "On: Signalbox's breakers hold new coders."],
            "reaping.signalbox"                  => ["Off: the plain sweep reaps.", "On: Signalbox rules each reap."],
            "signalbox_response.drives"          => ["Off: a heavy job waits on memory.", "On: a heavy job answers the band."],
            "metering.roundhouse"                => ["Off: the load is read from uptime.",
                                                     "On: the load is read from Roundhouse's meter."],
            "work_cap.moves"                     => ["Off: the fixed work cap holds.",
                                                     "On: the work cap moves inside its bounds."],
            "dispatch_roll_forward.roll_forward" => ["Off: the fill starts nothing.", "On: the fill starts work as places free."]
          }.freeze

          module_function

          # @param setting [String] a setting name
          # @param reading [Hash] {InForce.reading}
          # @return [String, nil] what the switch has decided, nil for a setting that is no switch
          def word(setting, reading)
            return pressure(reading) if setting == "signalbox_pressure.drives"

            verb, key = setting.split(".")
            WORDS[setting]&.fetch(reading[:row].call(verb)[key.to_sym] == true ? 1 : 0)
          end

          # @param reading [Hash] {InForce.reading}
          # @return [String] what the pressure switch and the signal's state decide together
          def pressure(reading)
            return "Off: the load guards, the moving cap and the heavy-jobs gate keep their own readings." unless reading[:drives]
            return "On, and Signalbox's signal is current: its marks govern." if reading[:signal]

            "On, but the signal is dark: each reader keeps its own reading."
          end

          # @param reading [Hash] {InForce.reading}
          # @return [String] why Signalbox's mark is not yet the one that governs
          def dark(reading)
            return "Signalbox's signal is dark, so its mark is standing by." if reading[:drives]

            "Signalbox's mark stands by until signalbox_pressure.drives is on."
          end
        end
      end
    end
  end
end
