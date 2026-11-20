# frozen_string_literal: true

require "hecks/signalbox/adapters/looking/view"

module Hecks
  module Adapters
    class MainIntegration
      # The shell step that keeps the train copy's machine-local files equal to the main checkout's.
      # It is built from the lists the beat's view judges those files by, so a file the view counts
      # as missing is a file this step copies. A copy that is the main checkout, or a failed copy,
      # never stops the beat.
      module LocalCopy
        VIEW = Adapters::Looking::View

        # @return [String] the step, plain shell run from the copy's root
        def self.step
          "{ primary=$(cd \"$(git rev-parse --git-common-dir)/..\" && pwd) && [ \"$primary\" != \"$PWD\" ] && " \
            "for f in #{globs}; do rel=${f#\"$primary\"/}; case $rel in #{skipped}) continue;; esac; " \
            "mkdir -p \"$(dirname \"$rel\")\" && { cmp -s \"$f\" \"$rel\" || cp \"$f\" \"$rel\"; }; done; } " \
            "2>/dev/null; true"
        end

        def self.globs = VIEW::LOCAL.map { |glob| "${primary}/#{glob}(N)" }.join(" ")

        def self.skipped = VIEW::SKIPPED.map { |dir| "#{dir}*" }.join("|")
      end
    end
  end
end
