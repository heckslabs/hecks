# frozen_string_literal: true

require_relative "candidates"
require_relative "../../git"

module Hecks
  module Adapters
    module Codebase
      module Promotion
        # How long a lane has stood behind the lane it follows, against what its `Lane` row allows.
        #
        # It reads the remote and the clock and answers hours as value objects. It does not judge
        # them: the policies of `PromotionRun` fault a lane that is late, and the fault files a
        # finding. A lane whose row allows no lag is never late.
        class Watch
          SECONDS_PER_HOUR = 3600

          # @param held [Hash] the `PromotionRun` record: `lane`
          # @param tree [Tree] the checkout, already known to be one
          def initialize(held, tree)
            @lane_name = Promotion.plain(held[:lane])
            @lane = Promotion.row(@lane_name)
            @where = tree.root
            @repo = Promotion.git || Git.new
          end

          # @return [Hash{Symbol => Hash}] `lane_known`, `behind_hours`, `limit_hours`, `promoted`
          #   and the `reason`, as value objects
          def facts
            return Promotion.unknown(@lane_name) unless @lane && !source.empty?

            fetch
            Promotion.watched(behind, limit, late? ? lateness : "#{name} is on time: #{behind}h behind, #{limit}h allowed")
          end

          private

          def name = @lane["name"]

          def source = @lane["follows"].to_s

          def limit = @lane["alert_after"].to_i

          def late? = behind > limit

          def fetch
            @repo.capture("fetch", "origin", source, chdir: @where)
            @repo.capture("fetch", "origin", name, chdir: @where)
          end

          # Whole hours since the oldest commit the followed lane has and this lane lacks.
          def behind
            @behind ||= limit.zero? ? 0 : hours_since(oldest_unpromoted)
          end

          def oldest_unpromoted
            held = @repo.remote_head("refs/heads/#{name}", chdir: @where)
            @repo.oldest_commit_time(held && "origin/#{name}", "origin/#{source}", chdir: @where)
          end

          def hours_since(time) = time ? (Promotion.now.to_i - time) / SECONDS_PER_HOUR : 0

          def lateness
            "#{name} has stood #{behind}h behind #{source} (its Lane row allows #{limit}h): #{checks_on_source}"
          end

          # Tells a lane that is merely waiting on CI from one whose promotion is stuck: a certified
          # commit the lane has not reached means the promotion should have run, whatever the
          # head of the followed lane is doing.
          def checks_on_source
            head = @repo.remote_head("refs/heads/#{source}", chdir: @where)
            candidates = Candidates.new(@repo, @where, head, @repo.remote_head("refs/heads/#{name}", chdir: @where))
            certified = candidates.newest_certified
            return "every required check passed on #{certified[0, 7]}, so a promotion should have run" if certified

            why = candidates.gate(head).why
            why.empty? ? "#{head[0, 7]} passed every required check but is not a fast-forward of #{name}" : why
          end
        end
      end
    end
  end
end
