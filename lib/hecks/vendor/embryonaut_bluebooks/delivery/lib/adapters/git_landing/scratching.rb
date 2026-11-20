# frozen_string_literal: true

require "hecks/hecks/adapters/landing/worktree_scratch"

module Hecks
  module Adapters
    class GitLanding
      # Takes a linked worktree down: clears the regenerable scratch (`tmp`, `.ruby-lsp`, a crate's
      # `target`) first, so only what cannot be regenerated keeps it, then retires it through
      # {Tidy}. The main checkout and a protected branch's tree never have their scratch cleared,
      # since {Tidy} refuses them. A linked worktree's scratch is cleared before {Tidy} decides,
      # even when it then refuses, since {Tidy} counts ignored files as unsaved. The scratch list
      # is the world's `worktree_scratch` setting of the `reaping` line, or the `scratch:`
      # override. The including class answers `settle`, `plain` and `current_branch`.
      module Scratching
        private

        def take_down(held, mode, outcome)
          settle(held)
          branch = plain(held[:branch]) || current_branch
          gone = tree_to_take_down(held, branch)
          clear_scratch(gone) if scratch_clearable?(gone, branch)
          kept, said = Tidy.new(@git, gone, branch: branch, onto: plain(held[:onto]) || "main", mode: mode).retire
          raise ConsoleCapture::Failure, "#{gone} is kept: #{said}" if kept

          { outcome: { value: outcome }, checkout: { value: gone }, branch: { value: branch },
            report: { value: block_given? ? yield(said) : said } }
        end

        # The worktree a retirement names: the `checkout` given, or the one holding `branch` when
        # none is given or the one given is the primary checkout. The primary is never a retire
        # target, so a branch with no linked worktree leaves it for {Tidy} to refuse by name.
        # It returns the path and leaves `@checkout`, the repository's top level, as it was.
        def tree_to_take_down(held, branch)
          return @checkout if plain(held[:checkout]) && !main_checkout?(@checkout)

          worktree_on(branch)&.path || @checkout
        end

        def scratch_clearable?(path, branch) = !main_checkout?(path) && !Tidy::PROTECTED.include?(branch)

        def main_checkout?(path) = File.identical?(path, primary.path)

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
