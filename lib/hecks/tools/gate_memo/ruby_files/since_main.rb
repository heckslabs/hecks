# frozen_string_literal: true

require "open3"

module Hecks
  module Tools
    module GateMemo
      module RubyFiles
        # The Ruby files a branch changed since it left `main`, which RuboCop lints whatever the
        # memo holds. A memo baseline can already hold a branch's files, and a style offense in
        # them must still stop the landing; this keeps the landing, the push and `gate_run` in
        # agreement.
        module SinceMain
          module_function

          # @param root [String] the checkout
          # @param plan [Array(Symbol, Array<String>, String)] the memo's plan: mode, files, why
          # @param now [Hash{String => String}] the checkout's Ruby files and their hashes
          # @return [Array(Symbol, Array<String>, String)] the plan, widened to lint the files
          #   changed since `main` and the files that require them; a full run stays full
          def widen(root, plan, now)
            mode, files, why = plan
            return plan if mode == :full

            extra = lintable(root, changed(root) & now.keys, now)
            return plan if extra.empty?

            [:incremental, (files + extra).uniq.sort, "#{why}; #{extra.size} changed since main"]
          end

          # @return [Array<String>] the files to lint for the changed ones, requirers included
          def lintable(root, changed, now)
            return [] if changed.empty?

            RubyFiles.lintable(root, RubyFiles.closure(root, changed, now.keys))
          end

          # @return [Array<String>] the Ruby files that differ from the merge-base with `main`, or
          #   none when the checkout has no `main` to compare with
          def changed(root)
            base, status = Open3.capture2("git", "-C", root, "merge-base", "HEAD", "main", err: File::NULL)
            return [] unless status.success?

            out, = Open3.capture2("git", "-C", root, "diff", "--name-only", "--diff-filter=d", base.strip, "--", "*.rb",
                                  err: File::NULL)
            out.split("\n")
          end
        end
      end
    end
  end
end
