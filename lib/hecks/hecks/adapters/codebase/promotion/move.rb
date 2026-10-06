# frozen_string_literal: true

require_relative "../../git"

module Hecks
  module Adapters
    module Codebase
      module Promotion
        # One accepted promotion carried out: a fast-forward of the lane onto the commit and, when
        # the `Lane` row says the lane `feeds` a tag, a forward-only move of that tag.
        #
        # Unconfirmed it names the move and makes none. A lane that already holds the commit is not
        # moved, but a confirmed run still brings the tag it feeds up to the lane's head, so a tag
        # left behind by a half-finished promotion is repaired by the next one.
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
            return already_held if held?
            return Promotion.outcome("rehearsal: would fast-forward #{span} (add --confirm to move it)", false) unless confirmed?

            @repo.fast_forward(@commit, name, chdir: @root)
            Promotion.outcome("fast-forwarded #{span}#{feed_note(@commit)}", true)
          end

          private

          # A lane that holds the commit is not moved, but the tag it feeds is still brought up
          # to the lane: a promotion that moved the lane and then failed on the tag is finished
          # by the next run, whichever commit that run is about, not left behind for good.
          def already_held
            said = "#{name} already holds #{short(@commit)}"
            return Promotion.outcome(said, false) unless confirmed? && feeds?

            moved = @repo.move_tag(feed, @args[:head], chdir: @root)
            Promotion.outcome("#{said}, #{feed} #{moved}", moved != :current)
          end

          def feed = @lane["feeds"].to_s

          def feeds? = !feed.empty?

          def name = @lane["name"]

          def confirmed? = @args[:confirm]

          def span = "#{name} #{short(@args[:head])}..#{short(@commit)}"

          def short(commit) = commit.to_s[0, 7]

          def held? = @args[:head] != "none" && @repo.ancestor?(@commit, @args[:head], chdir: @root)

          # @param onto [String] the commit the fed tag should name
          def feed_note(onto) = feeds? ? ", #{feed} #{@repo.move_tag(feed, onto, chdir: @root)}" : ""
        end
      end
    end
  end
end
