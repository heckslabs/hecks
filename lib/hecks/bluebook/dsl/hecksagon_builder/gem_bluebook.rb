module Hecks
  module Bluebook
    module DSL
      class HecksagonBuilder
        # The hecksagon word that loads a bluebook the gem carries by the hecksagon's own name, for
        # a directory that holds only wiring. Included into `HecksagonBuilder`.
        module GemBluebook
          # Loads the bluebook the gem carries under this hecksagon's own name, for a directory that
          # holds only wiring (the QA ledger's `qa/bluebook` keeps its hecksagon and world while the
          # bluebook ships in `lib/hecks/quality_control/`). Unlike `attaches` it records no
          # attachment and marks nothing bounded; it brings the bluebook in so the binds after it
          # can name its aggregates, so it comes first in the block.
          #
          # @param source [Symbol] `:gem`, the one source there is
          # @return [void]
          # @raise [Runtime::WiringError] for any other source
          def bluebook_from(source)
            raise Runtime::WiringError, "bluebook_from #{source.inspect} — it takes only :gem" unless source == :gem

            @bluebook_from = "gem"
            require_relative "../../../framework_bluebooks"
            self.class.with_real_modules { Hecks::FrameworkBluebooks.load!(@domain.to_s) }
          end
        end
      end
    end
  end
end
