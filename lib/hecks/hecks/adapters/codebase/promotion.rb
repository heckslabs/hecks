# frozen_string_literal: true

require "hecks/vocabulary"
require_relative "tree"
require_relative "../git"
require_relative "../../../quality_control/adapters/github_checks"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `PromotionRun` asks of the working tree and the remote: the facts a
      # promotion is judged by, and the move itself once it is accepted.
      #
      # The rules are not here. `facts` only reports where things stand (which lane, where its head
      # is, where each `RequiredCheck` stands against the commit) and the givens of
      # `PromotionRun.Accept` decide. `call` makes the move: a fast-forward of the lane and, when
      # the `Lane` row says the lane `feeds` a tag, a forward-only move of that tag. Unconfirmed it
      # names the move and makes none.
      module Promotion
        # Every operation this family carries out.
        OPERATIONS = %w[promote].freeze

        class << self
          # @return [Git, nil] reads and moves refs; a `Git` when nil. A spec replaces it.
          attr_accessor :git

          # @return [#states, nil] reports where each check stands against a commit; `GithubChecks`
          #   when nil. A spec replaces it, so nothing asks GitHub.
          attr_accessor :checks
        end

        module_function

        # The facts of a promotion, answered without judging them.
        #
        # @param held [Hash] the `PromotionRun` record: `lane`, and `commit` when one was named
        # @param tree [Tree] the checkout, already known to be one
        # @return [Hash{Symbol => Hash}] `lane_known`, `green`, `descends`, `commit`, `head` and the
        #   `reason` they were not all true, as value objects
        def facts(held, tree)
          lane = row(plain(held[:lane]))
          return unknown(plain(held[:lane])) unless lane && !lane["follows"].to_s.empty?

          source = lane["follows"]
          repo = Promotion.git || Git.new
          where = tree.root
          head = repo.remote_head("refs/heads/#{lane['name']}", chdir: where)
          source_head = repo.remote_head("refs/heads/#{source}", chdir: where)
          commit = plain(held[:commit]) || source_head
          return unknown(lane["name"], "#{source} has no head on origin") unless commit

          fetch(repo, lane["name"], source, head, where)
          green, why = required_checks(commit)
          descends = on_source?(repo, commit, source_head, where) && (head.nil? || forward_or_held?(repo, head, commit, where))
          answer(commit, head, green, descends, why, source)
        end

        # The facts of a tree that is not a checkout: placeholders that satisfy the value objects,
        # so the checkout rule is the one that refuses.
        #
        # @return [Hash{Symbol => Hash}] every fact a promotion is judged by, none of them true
        def no_facts = unknown("none", "needs a hecks checkout: hecks.gemspec stands beside lib/")

        # Carries out an accepted promotion.
        #
        # @param operation [String] `promote`
        # @param held [Hash] the `PromotionRun` record's fields: `lane`, `commit`, `confirm`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused; the move goes through the `Git` adapter
        # @return [Hash{Symbol => Hash}] `report:` what was, or would be, moved, and `promoted:`
        #   whether the remote was changed
        # @raise [ConsoleCapture::Failure] when the remote refuses the move
        def call(operation, held, tree, shell: nil)
          _ = [operation, shell]
          args = held.transform_values { |value| plain(value) }
          lane = row(args[:lane])
          commit = args.fetch(:commit)
          move = "#{lane['name']} #{short(args[:head])}..#{short(commit)}"
          repo = Promotion.git || Git.new
          held = args[:head] != "none" && repo.ancestor?(commit, args[:head], chdir: tree.root)
          return outcome("#{lane['name']} already holds #{short(commit)}", false) if held
          return outcome("rehearsal: would fast-forward #{move} (add --confirm to move it)", false) unless args[:confirm]

          repo.fast_forward(commit, lane["name"], chdir: tree.root)
          feed = lane["feeds"].to_s
          moved = feed.empty? ? "" : ", #{feed} #{repo.move_tag(feed, commit, chdir: tree.root)}"
          outcome("fast-forwarded #{move}#{moved}", true)
        end

        # @param name [String] a lane's name
        # @return [Hash{String => String}, nil] the `Lane` row of that name
        def row(name) = Hecks::Vocabulary.rows("Lane").find { |lane| lane["name"] == name }

        # @param commit [String] the commit to judge
        # @return [Array(Boolean, String)] whether every `RequiredCheck` passed, and what it was not
        def required_checks(commit)
          names = Hecks::Vocabulary.rows("RequiredCheck").map { |check| check["name"] }
          states = (Promotion.checks || GithubChecks.new).states(commit: commit, names: names)
          failed = states.select { |_, state| state == :failed }.keys
          waiting = states.select { |_, state| %i[pending missing].include?(state) }.keys
          why = [("failed: #{failed.join(', ')}" unless failed.empty?),
                 ("waiting on: #{waiting.join(', ')}" unless waiting.empty?)].compact.join("; ")
          [failed.empty? && waiting.empty?, why]
        end

        # A commit the lane already holds needs no move, and a commit that contains the lane's head
        # is a fast-forward; only one that is neither would rewind or fork the lane.
        def forward_or_held?(repo, head, commit, where)
          repo.ancestor?(head, commit, chdir: where) || repo.ancestor?(commit, head, chdir: where)
        end

        # A commit is on the lane a promotion draws from when that lane's head contains it.
        def on_source?(repo, commit, source_head, where)
          !source_head.nil? && repo.ancestor?(commit, source_head, chdir: where)
        end

        # The history a fast-forward test needs, which a shallow clone lacks.
        def fetch(repo, lane, source, head, where)
          repo.capture("fetch", "origin", source, chdir: where)
          repo.capture("fetch", "origin", lane, chdir: where) if head
        end

        def answer(commit, head, green, descends, why, source)
          reason = []
          reason << why unless green
          reason << "the commit is not a fast-forward of the lane, or not on #{source}" unless descends
          { lane_known: { value: true }, green: { value: green }, descends: { value: descends },
            commit: { value: commit }, head: { value: head || "none" }, reason: { value: reason.join("; ") } }
        end

        def unknown(lane, why = nil)
          { lane_known: { value: false }, green: { value: false }, descends: { value: false },
            commit: { value: "none" }, head: { value: "none" },
            reason: { value: why || "#{lane.inspect} is not a Lane row that follows another lane" } }
        end

        def outcome(text, promoted) = { report: { value: text }, promoted: { value: promoted } }

        def short(commit) = commit.to_s[0, 7]

        def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
      end
    end
  end
end
