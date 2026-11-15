# frozen_string_literal: true

require "hecks/hecks/adapters/landing/worktree_scratch"

module Hecks
  module Adapters
    class GitLanding
      # Takes a linked worktree down: clears the regenerable scratch (`tmp`, `.ruby-lsp`, a crate's
      # `target`) first, so only what cannot be regenerated keeps it, then retires it through
      # {Tidy}. The scratch list is the world's `worktree_scratch` setting of the `reaping` line,
      # or the `scratch:` override. The including class answers `settle`, `plain` and
      # `current_branch`.
      module Scratching
        private

        def take_down(held, mode, outcome)
          settle(held)
          branch = plain(held[:branch]) || current_branch
          gone = @checkout
          clear_scratch(gone)
          kept, said = Tidy.new(@git, @checkout, branch: branch, onto: plain(held[:onto]) || "main", mode: mode).retire
          raise ConsoleCapture::Failure, "#{gone} is kept: #{said}" if kept

          { outcome: { value: outcome }, checkout: { value: gone }, branch: { value: branch },
            report: { value: block_given? ? yield(said) : said } }
        end

        def clear_scratch(path)
          globs = scratch_globs
          WorktreeScratch.new(globs: globs).clear(path) unless globs.empty?
        end

        def scratch_globs
          world = @registry&.world("Hecks")
          Array(@tune[:scratch] || world&.for_verb("reaping")&.dig(:worktree_scratch)).map(&:to_s)
        end
      end
    end
  end
end
