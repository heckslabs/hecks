# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module EraReattest
      # What the re-attestation says to the person running it.
      module Reporting
        # @return [Integer] 0
        def matches_digest(bluebook, ordinal)
          puts "#{bluebook.name} era #{ordinal}: the held text matches its digest — nothing to re-attest."
          0
        end

        def report_mismatch(bluebook, ordinal, stored, computed)
          puts "#{bluebook.name} era #{ordinal}: the held text does NOT match its recorded digest."
          puts "  recorded: #{stored || "(none)"}"
          puts "  computed: #{computed}"
        end

        # Says how the held text's shape compares with the era's minted name.
        #
        # @param verdict [Symbol, nil] `:cosmetic`, `:unnamed`, or nothing to say
        def report_shape(verdict, ordinal)
          case verdict
          when :cosmetic
            puts "  shape:    unchanged — the edit is cosmetic (the text still projects to era #{ordinal}'s " \
                 "minted name)"
          when :unnamed
            puts "  shape:    era #{ordinal} was never named, so no shape comparison is possible — read carefully"
          end
        end

        # @return [void]
        def show(text)
          puts
          puts "The held text AS IT NOW STANDS — the original is gone; this is what you would be attesting to:"
          puts "─" * 72
          puts text
          puts "─" * 72
        end

        # @return [Integer] 1
        def refuse_without_accept
          puts
          puts "REFUSED: nothing changed. If you have read the text above and accept it as this era's"
          puts "frozen source, run again with --accept. The attestation (old digest, new digest, when)"
          puts "goes on the record either way you decide."
          1
        end
      end
    end
  end
end
