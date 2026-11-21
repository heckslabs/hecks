# frozen_string_literal: true

require "hecks/signalbox/adapters/looking/view"

module Hecks
  module Adapters
    class MainIntegration
      # The shell step that keeps the train copy's machine-local files equal to the main checkout's.
      # It is built from the lists the beat's view judges those files by, so a file the view counts
      # as missing is a file this step copies. A copy that is the main checkout, or a failed copy,
      # never stops the beat. The step is plain POSIX shell, so it needs no zsh.
      module LocalCopy
        VIEW = Adapters::Looking::View

        # @return [String] the step, run from the copy's root
        def self.step
          "{ primary=$(cd \"$(git rev-parse --git-common-dir)/..\" && pwd) && [ \"$primary\" != \"$PWD\" ] && " \
            "find \"$primary\" #{pruned} -o #{named} -type f -print | while IFS= read -r f; do " \
            "rel=${f#\"$primary\"/}; mkdir -p \"$(dirname \"$rel\")\" && " \
            "{ cmp -s \"$f\" \"$rel\" || cp \"$f\" \"$rel\"; }; done; } 2>/dev/null; true"
        end

        def self.named = "\\( #{VIEW::LOCAL.map { |glob| "-name '#{File.basename(glob)}'" }.join(" -o ")} \\)"

        def self.pruned
          "\\( #{VIEW::SKIPPED.map { |dir| "-path \"$primary/#{dir.chomp("/")}\"" }.join(" -o ")} \\) -prune"
        end
      end
    end
  end
end
