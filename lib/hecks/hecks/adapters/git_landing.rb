# frozen_string_literal: true

require_relative "git_worktrees"
require_relative "git_main_pull"
require_relative "git_landing/merger"
require_relative "git_landing/tidy"
require_relative "git_landing/rivals"
require_relative "git_landing/finisher"
require_relative "git_landing/lineup"
require_relative "../../indifferent_key"

module Hecks
  module Adapters
    # The `Worktrees` port's adapter for `Landing`: merges a worktree's branch onto local `main`,
    # retires a worktree and its branch once they are merged, and lists what is not on `main`.
    #
    # It never pushes, never forces, and never resolves a conflict. Retiring refuses a worktree
    # that holds uncommitted work or a branch with commits `main` lacks, so no unpushed work goes.
    class GitLanding
      include GitWorktrees
      include GitMainPull

      # Accepts the arguments every driven adapter is built with; only the registry and the
      # overrides are kept.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] where the started Work rows are read
      # @param tune [Hash] overrides of the line's limits and collaborators (see `Lineup`)
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, **tune)
        @git = Git.new
        @registry = registry
        @tune = tune
      end

      # Lands a worktree's branch onto another branch (local `main` by default), then removes the
      # linked worktree and branch it landed from when they hold nothing main lacks.
      #
      # @param held [Hash] the `Landing` record: `checkout` (a directory inside the worktree; the
      #   current directory when absent), `branch` (its checked-out branch when absent), `onto`
      # @return [Hash{Symbol => Hash}] the answer `Merger#land` describes
      # @raise [ConsoleCapture::Failure] on a conflict, uncommitted work, or no such branch
      def merge(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = plain(held[:onto]) || "main"
        raise ConsoleCapture::Failure, "#{branch} is the branch to land onto" if branch == onto

        lineup.stand(branch, onto: onto, checkout: @checkout) { |note| land_alone(branch, onto, note) }
      end

      # Takes the front place in the line and lands every branch whose landing is waiting behind
      # it, in ticket order, without giving the place up: each is rebased onto the moving `onto`,
      # run through the quick gate and landed. One that conflicts, fails the gate or overlaps
      # another started row's area is skipped with its reason, and its own waiting `land!` is told.
      #
      # @param held [Hash] the `Landing` record: `checkout` (any directory in the repository) and
      #   `onto`
      # @return [Hash{Symbol => Hash}] `outcome:` (`trained`), `checkout:`, `branch:` and `report:`
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository or the wait runs out
      def convene(**held)
        settle(held)
        onto = plain(held[:onto]) || "main"
        land = ->(checkout, branch, target) { land_for(checkout, branch, target) }
        said = lineup.convoy(@git, @checkout, onto: onto, land: land)
        { outcome: { value: "trained" }, checkout: { value: primary.path }, branch: { value: "train" }, report: { value: said } }
      end

      # Finishes a branch in one step: refuses unsaved work, rebases it onto `onto`, runs the quick
      # gate in its worktree, lands it through the queue and tidies the worktree.
      #
      # @param held [Hash] the `Landing` record, as for {#merge}; `gate:` (a callable) replaces the
      #   gate run, for a spec
      # @return [Hash{Symbol => Hash}] the answer {#merge} gives
      # @raise [ConsoleCapture::Failure] at the first step that fails, naming it: unsaved work,
      #   conflict, gate red, or the queue busy
      def finish_branch(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = plain(held[:onto]) || "main"
        raise ConsoleCapture::Failure, "#{branch} is the branch to land onto" if branch == onto

        Finisher.new(@git, @checkout, branch: branch, onto: onto, gate: held[:gate]).prepare
        @retiring = true
        merge(**held)
      ensure
        @retiring = false
      end

      # Removes a linked worktree and deletes its branch, once the branch is on `onto`.
      #
      # @param held [Hash] the `Landing` record: `checkout` (the worktree to remove), `branch`
      #   (its checked-out branch when absent), `onto`
      # @return [Hash{Symbol => Hash}] `outcome:` (`retired`), `checkout:`, `branch:`, `report:`
      # @raise [ConsoleCapture::Failure] when anything makes keeping it the safe answer: the primary
      #   worktree, one the process stands in, any file not tracked and clean (ignored included), a
      #   branch with commits `onto` lacks or a protected branch, or git refusing the removal
      def remove(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = plain(held[:onto]) || "main"
        gone = @checkout
        kept, said = Tidy.new(@git, @checkout, branch: branch, onto: onto, retiring: true).retire
        raise ConsoleCapture::Failure, "#{gone} is kept: #{said}" if kept

        { outcome: { value: "retired" }, checkout: { value: gone }, branch: { value: branch },
          report: { value: said } }
      end

      # The branches whose commits are not on a branch, or that hold uncommitted work.
      #
      # @param held [Hash] `checkout` (any directory in the repository), `onto` (default `main`)
      # @return [Hash{Symbol => String}] `text:` one tab-separated line per branch
      # @raise [Runtime::NotFound] when the checkout is not a repository
      def unlanded(**held)
        settle(held)
        onto = ref(plain(held[:onto]) || "main")
        lines = branches.reject { |name| name == onto }.filter_map { |name| unlanded_line(name, onto) }
        { text: lines.empty? ? "everything is on #{onto}\n" : "#{lines.join("\n")}\n" }
      rescue ConsoleCapture::Failure => e
        raise Runtime::NotFound, e.message
      end

      private

      # One landing from another worktree, as the train makes it for a waiting branch.
      def land_for(checkout, branch, onto)
        mine = @checkout
        @checkout = checkout
        land_alone(branch, onto, nil)
      ensure
        @checkout = mine
      end

      def land_alone(branch, onto, note)
        refuse_unsaved(branch)
        refuse_stale_base(branch) if onto == "main"
        refuse_rival(branch, onto)
        said = tidy(Merger.new(@git, @checkout, branch: branch, onto: onto).land, branch, onto)
        note ? said.merge(report: { value: "#{said[:report][:value]}; #{note}" }) : said
      end

      def common_git_dir = read("rev-parse", "--path-format=absolute", "--git-common-dir")

      # The line of this repository, with the limits of the world's `landing "Queue"` setting.
      def lineup
        setting = (@registry&.world("Hecks")&.settings || {})["landing"]
        Lineup.new(common_git_dir, setting: setting, **@tune)
      end

      def refuse_rival(branch, onto)
        clash = Rivals.new(@git, @checkout, @registry).refusal(branch, onto)
        raise ConsoleCapture::Failure, clash if clash
      end

      def tidy(landed, branch, onto)
        said = @retiring ? retire_from_primary(branch, onto) : Tidy.new(@git, @checkout, branch: branch, onto: onto).call
        landed.merge(report: { value: "#{landed[:report][:value]}; #{said}" })
      end

      # A finish runs inside the worktree it retires, so the process leaves it first; a worktree
      # that
      # holds ignored files is kept and said so.
      def retire_from_primary(branch, onto)
        Dir.chdir(primary.path) do
          kept, said = Tidy.new(@git, @checkout, branch: branch, onto: onto, retiring: true).retire
          kept ? "kept #{branch}: #{said}" : said
        end
      end

      def refuse_unsaved(branch)
        tree = worktree_on(branch)
        changed = tree ? dirty(tree.path) : []
        raise ConsoleCapture::Failure, "#{tree.path} holds uncommitted work: #{changed.join(", ")}" unless changed.empty?
      end

      def branches = read("for-each-ref", "--format=%(refname:short)", "refs/heads").split("\n")

      def unlanded_line(name, onto)
        ahead = count("#{onto}..#{name}")
        tree = worktree_on(name)
        changed = tree ? dirty(tree.path).size : 0
        return nil if ahead.zero? && changed.zero?

        [name, "#{ahead} commit(s) not on #{onto}", tree&.path || "no worktree", "#{changed} uncommitted"].join("\t")
      end
    end
  end
end
