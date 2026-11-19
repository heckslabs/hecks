require "tmpdir"
require_relative "../../hecks/adapters/console_capture"

module Hecks
  module SME
    module DiscoveryProjection
      # Stages projected bluebook text as the one file of a temporary directory and runs
      # `model_check` over it (ADR 0194, decision 10), since the check runs on directories.
      #
      # `Hecks::Tools::ModelCheck.call` prints and always exits: 0 when clean, 1 with findings or
      # when the text is malformed (its `abort`). Text that is not Ruby at all raises while it
      # loads, and that is a verdict too, never clean. Both streams are captured through
      # `Adapters::ConsoleCapture`, which holds the process-wide lock, so two checks never
      # interleave their output.
      module StagedCheck
        # The staged file's fixed name: the subject names the bluebook inside it, never the path.
        FILE = "staged.bluebook".freeze

        # What the check said of the staged text.
        #
        # @!attribute [r] clean
        #   @return [Boolean] true only when `model_check` exited 0
        # @!attribute [r] report
        #   @return [String] everything it printed, findings and verdict
        Verdict = Struct.new(:clean, :report, keyword_init: true)

        module_function

        # @param text [String] bluebook text, as `DiscoveryProjection.text` answers it
        # @return [Verdict] clean or not, with what the check printed
        def call(text)
          require_relative "../../tools/model_check"
          Dir.mktmpdir("discovery") do |dir|
            File.write(File.join(dir, FILE), text)
            outcome = Adapters::ConsoleCapture.capture { Tools::ModelCheck.call([dir], program: "hecks model_check") }
            Verdict.new(clean: outcome.ok?, report: outcome.output)
          end
        rescue ScriptError, StandardError => e
          Verdict.new(clean: false, report: "#{e.class}: #{e.message}")
        end
      end
    end
  end
end
