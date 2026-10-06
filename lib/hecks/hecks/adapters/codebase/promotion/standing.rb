# frozen_string_literal: true

require_relative "candidates"
require_relative "../../git"

module Hecks
  module Adapters
    module Codebase
      module Promotion
        # Where a lane, the lane it follows and a commit stand: the facts a promotion is judged by.
        #
        # It reads the remote and the checks and answers them as value objects. It does not judge
        # them; `PromotionRun.Accept` holds the rules. Without a named commit it offers the newest
        # commit of the followed lane that passed every check, so the answer does not depend
        # on which commit's CI run happened to start the promotion.
        class Standing
          # @param held [Hash] the `PromotionRun` record: `lane`, and `commit` when one was named
          # @param tree [Tree] the checkout, already known to be one
          def initialize(held, tree)
            @lane_name = Promotion.plain(held[:lane])
            @lane = Promotion.row(@lane_name)
            @named = Promotion.plain(held[:commit])
            @where = tree.root
            @repo = Promotion.git || Git.new
          end

          # @return [Hash{Symbol => Hash}] `lane_known`, `green`, `descends`, `commit`, `head` and
          #   the `reason` they were not all true
          def facts
            return Promotion.unknown(@lane_name) unless follower?
            return Promotion.unknown(@lane["name"], "#{source} has no head on origin") unless source_head

            fetch
            answer
          end

          private

          def follower? = @lane && !@lane["follows"].to_s.empty?

          def source = @lane["follows"]

          # The commit named, else the newest one of the followed lane that every required check
          # passed on, else its head, so that a refusal says what the head is waiting on.
          def commit = @commit ||= @named || candidates.newest_certified || source_head

          def candidates = @candidates ||= Candidates.new(@repo, @where, source_head, head)

          def head = remember(:@head) { remote("refs/heads/#{@lane["name"]}") }

          def source_head = remember(:@source_head) { remote("refs/heads/#{source}") }

          # Memoizes a value that may be nil: an absent lane is asked about once, not on each use.
          def remember(name)
            return instance_variable_get(name) if instance_variable_defined?(name)

            instance_variable_set(name, yield)
          end

          def remote(ref) = @repo.remote_head(ref, chdir: @where)

          def ancestor?(older, newer) = @repo.ancestor?(older, newer, chdir: @where)

          # The history a fast-forward test needs, which a shallow clone lacks.
          def fetch
            @repo.capture("fetch", "origin", source, chdir: @where)
            @repo.capture("fetch", "origin", @lane["name"], chdir: @where) if head
          end

          # A commit is on the lane a promotion draws from when that lane's head contains it.
          def on_source? = !source_head.nil? && ancestor?(commit, source_head)

          # A commit the lane already holds needs no move, and a commit that contains the lane's
          # head is a fast-forward; only one that is neither would rewind or fork the lane.
          def forward_or_held? = head.nil? || ancestor?(head, commit) || ancestor?(commit, head)

          def answer
            gate = candidates.gate(commit)
            descends = on_source? && forward_or_held?
            Promotion.answer(commit, head, gate.green?, descends, [gate.why, descends ? nil : not_forward].compact)
          end

          def not_forward = "the commit is not a fast-forward of the lane, or not on #{source}"
        end
      end
    end
  end
end
