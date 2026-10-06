# frozen_string_literal: true

require_relative "../../git"

module Hecks
  module Adapters
    module Codebase
      module Promotion
        # One accepted promotion carried out: a fast-forward of the lane onto the commit and, when
        # the `Lane` row says the lane `feeds` a tag, a forward-only move of that tag.
        #
        # Unconfirmed it names the move and makes none, and a lane that already holds the commit is
        # left alone.
        class Move
          # @param held [Hash] the `PromotionRun` record: `lane`, `commit`, `head`, `confirm`
          # @param tree [Tree] the checkout, already known to be one
          def initialize(held, tree)
            @args = held.transform_values { |value| Promotion.plain(value) }
            @lane = Promotion.row(@args[:lane])
            @commit = @args.fetch(:commit)
            @root = tree.root
            @repo = Promotion.git || Git.new
          end

          # @return [Hash{Symbol => Hash}] `report:` what was, or would be, moved, and `promoted:`
          #   whether the remote was changed
          # @raise [ConsoleCapture::Failure] when the remote refuses the move
          def carry_out
            return Promotion.outcome("#{name} already holds #{short(@commit)}", false) if held?
            return Promotion.outcome("rehearsal: would fast-forward #{span} (add --confirm to move it)", false) unless confirmed?

            @repo.fast_forward(@commit, name, chdir: @root)
            Promotion.outcome("fast-forwarded #{span}#{feed_note}", true)
          end

          private

          def name = @lane["name"]

          def confirmed? = @args[:confirm]

          def span = "#{name} #{short(@args[:head])}..#{short(@commit)}"

          def short(commit) = commit.to_s[0, 7]

          def held? = @args[:head] != "none" && @repo.ancestor?(@commit, @args[:head], chdir: @root)

          def feed_note
            feed = @lane["feeds"].to_s
            feed.empty? ? "" : ", #{feed} #{@repo.move_tag(feed, @commit, chdir: @root)}"
          end
        end
      end
    end
  end
end
