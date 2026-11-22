# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "tree"
require_relative "promotion/standing"
require_relative "promotion/move"
require_relative "promotion/watch"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `PromotionRun` asks of the working tree and the remote: the facts a
      # promotion is judged by, and the move itself once it is accepted.
      #
      # The rules are not here. `Standing` only reports where things stand (which lane, where its
      # head is, where each `RequiredCheck` stands against the commit) and the givens of
      # `PromotionRun.Accept` decide. `Move` carries it out: a fast-forward of the lane and, when
      # the `Lane` row says the lane `feeds` a tag, a forward-only move of that tag. Unconfirmed it
      # names the move and makes none.
      module Promotion
        # Every operation this family carries out.
        OPERATIONS = %w[promote watch].freeze

        class << self
          # @return [Git, nil] reads and moves refs; a `Git` when nil. A spec replaces it.
          attr_accessor :git

          # @return [#states, nil] reports where each check stands against a commit; `GithubChecks`
          #   when nil. A spec replaces it, so nothing asks GitHub.
          attr_accessor :checks

          # @return [#call, nil] answers the time now; the system clock when nil. A spec sets it.
          attr_accessor :clock

          # @return [#states] the checks reader: the one a spec replaced it with, else one shared
          #   `GithubChecks`, so the wait for a rate limit is one budget for the whole run
          def reader = checks || (@reader ||= GithubChecks.new)

          # @return [Time] the time now
          def now = (clock || -> { Time.now }).call
        end

        module_function

        # The facts of a promotion or of a watch, answered without judging them.
        #
        # @param held [Hash] the `PromotionRun` record: `operation`, `lane`, and `commit` when named
        # @param tree [Tree] the checkout, already known to be one
        # @return [Hash{Symbol => Hash}] for a promotion: `lane_known`, `green`, `descends`,
        #   `commit`, `head` and the `reason` they were not all true; for a watch: `lane_known`,
        #   `behind_hours`, `limit_hours` and the `reason`; all as value objects
        def facts(held, tree)
          watching = plain(held[:operation]) == "watch"
          (watching ? Watch : Standing).new(held, tree).facts
        rescue GithubChecks::RateLimited => e
          limited(e.message)
        end

        # The facts of a tree that is not a checkout: placeholders that satisfy the value objects,
        # so the checkout rule is the one that refuses.
        #
        # @return [Hash{Symbol => Hash}] every fact a promotion is judged by, none of them true
        def no_facts = unknown("none", "needs a hecks checkout: hecks.gemspec stands beside lib/")

        # Carries out an accepted promotion.
        #
        # @param operation [String] `promote`
        # @param held [Hash] the `PromotionRun` record's fields: `lane`, `commit`, `head`, `confirm`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused; the move goes through the `Git` adapter
        # @return [Hash{Symbol => Hash}] `report:` what was, or would be, moved, and `promoted:`
        #   whether the remote was changed
        # @raise [ConsoleCapture::Failure] when the remote refuses the move
        def call(operation, held, tree, shell: nil)
          _ = [operation, shell]
          Move.new(held, tree).carry_out
        end

        # @param name [String] a lane's name
        # @return [Hash{String => String}, nil] the `Lane` row of that name
        def row(name) = Hecks::Vocabulary.rows("Lane").find { |lane| lane["name"] == name }

        # @param commit [String] the commit to move onto
        # @param head [String, nil] where the lane stands, nil when it does not exist yet
        # @param green [Boolean] whether every required check passed
        # @param descends [Boolean] whether the move is a fast-forward from the followed lane
        # @param reasons [Array<String>] why the facts are not all true
        # @return [Hash{Symbol => Hash}] the facts, as value objects
        def answer(commit, head, green, descends, reasons)
          { lane_known: { value: true }, rate_limited: { value: false }, green: { value: green }, descends: { value: descends },
            commit: { value: commit }, head: { value: head || "none" },
            reason: { value: reasons.reject { |why| why.to_s.empty? }.join("; ") } }
        end

        # @param behind [Integer] whole hours the lane has stood behind the lane it follows
        # @param limit [Integer] whole hours its `Lane` row allows
        # @param reason [String] what the watch found
        # @return [Hash{Symbol => Hash}] the facts of a watch, as value objects
        def watched(behind, limit, reason)
          { lane_known: { value: true }, rate_limited: { value: false }, behind_hours: { value: behind },
            limit_hours: { value: limit },
            promoted: { value: false }, reason: { value: reason } }
        end

        # @param lane [String] the lane that was asked for
        # @param why [String, nil] what to say instead of the default
        # @return [Hash{Symbol => Hash}] facts none of which is true
        def unknown(lane, why = nil)
          { lane_known: { value: false }, rate_limited: { value: false }, green: { value: false }, descends: { value: false },
            commit: { value: "none" }, head: { value: "none" }, behind_hours: { value: 0 },
            limit_hours: { value: 0 }, promoted: { value: false },
            reason: { value: why || "#{lane.inspect} is not a Lane row that follows another lane" } }
        end

        # @param why [String] when GitHub will answer again, as the read of the checks said
        # @return [Hash{Symbol => Hash}] facts of a run that could not read the checks: none of them
        #   true and `rate_limited` true, so the run is deferred and not faulted
        def limited(why)
          unknown("none", "not promoted: #{why}").merge(rate_limited: { value: true })
        end

        # @return [Hash{Symbol => Hash}] what a finished move reports
        def outcome(text, promoted) = { report: { value: text }, promoted: { value: promoted } }

        def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
      end
    end
  end
end
