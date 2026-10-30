# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "../adapters/git_pr"
require_relative "qa_open_pr/arguments"
require_relative "qa_open_pr/rules"
require_relative "qa_open_pr/recording"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control patch.open`: opens a PR and records it in the
    # QualityControl ledger in one step. It is the only entry point into
    # `QualityControl::Patch.Open` and `QualityControl::Improvement.Open`.
    #
    # It refuses (exit 1, nothing opened or recorded) unless the ledger's own `Open` command would
    # take the record and the `GitPr` adapter agrees. The command's `given`s are the rules, asked
    # as a dry run before anything is opened: the branch starts with the practice's prefix; with
    # `--bug`, the bug is `fixed`; with `--angle`, it is `investigating`. The adapter answers the
    # rest: the tree is clean and the bug's commit is an ancestor of `HEAD`. The per-day cap
    # (`PR_CAP_PER_DAY`, 0 = uncapped) is `DailyQuota.Take`'s own `given`: asked as a dry run with
    # the others, and taken for real once the PR is recorded. It is idempotent. `QA_REPO_DIR`
    # picks the checkout `git` runs in, so a spec can use a throwaway repo and a fake `gh`.
    class QaOpenPr
      include Arguments
      include Rules
      include Recording

      EXIT_OK = 0

      USAGE = "usage: hecks quality_control patch.open --bug BUG#n --title \"…\" [--body \"…\"]\n       " \
              "hecks quality_control improvement.open --improvement [--angle ANGLE-n] --title \"…\" [--body \"…\"]"

      SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

      # Stands in for the commit of a bug that is not fixed yet, so its dry run reaches the `given`.
      PLACEHOLDER_COMMIT = "0000000"

      # Opens and records the PR.
      #
      # @param argv [Array<String>] `--bug`, `--improvement`, `--angle`, `--title` and `--body`
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` and `QA_REPO_DIR`
      # @return [Integer] 0 once opened and recorded
      # @raise [SystemExit] with `refused: ...` when a rule refuses, or the arguments are wrong
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` and `QA_REPO_DIR`
      def initialize(root:, env: ENV)
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
        @repo_dir = env.fetch("QA_REPO_DIR", root)
      end

      # @param argv [Array<String>] the command line's arguments
      # @return [Integer] the exit status
      # @raise [SystemExit] with `refused: ...` when a rule refuses, or the arguments are wrong
      def call(argv)
        options = parse(argv.dup)
        return EXIT_OK if options == :help

        @options = options
        prepare
        view = open_pull_request
        record(view)
        merge_when_green(view[:number]) if dial(:AUTO_MERGE, false)
        puts "#{view[:url]} (#{view[:headRefName]} @ #{view[:headRefOid].to_s[0, 7]}) — #{view[:title]}"
        EXIT_OK
      end

      private

      # Everything that can refuse, before a PR is opened.
      def prepare
        @git_pr = Hecks::Adapters::GitPr.new(repo_dir: @repo_dir)
        @branch = refusing { @git_pr.branch }
        refusing { @git_pr.assert_clean_tree! }
        @runtime = boot_ledger
        find_citations
        check_rules
      end

      # Every rule the adapter enforces refuses the same way: exit 1, nothing opened or recorded.
      def refusing
        yield
      rescue Hecks::Adapters::GitPr::Refusal, Hecks::Adapters::GitPr::CommandFailed => e
        abort "refused: #{e.message}"
      end

      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot — fix the ledger itself before opening a PR against it " \
              "(#{e.class}: #{e.message})"
      end

      def query(name, **args) = @runtime.query("QualityControl::#{name}", **args)

      # Falls back to a dial-less fixture ledger's values: uncapped, non-draft, no auto-merge.
      def dial(name, fallback)
        return fallback unless defined?(::QualityControlDials) && ::QualityControlDials.const_defined?(name)

        ::QualityControlDials.const_get(name)
      end

      # @return [Hash] `gh`'s view of the PR, opened here when the branch had none
      def open_pull_request
        view = existing_or_new_pull_request
        sha = view[:headRefOid].to_s
        unless sha.match?(SHA_PATTERN)
          abort "refused: gh reports head #{sha.inspect} for ##{view[:number]}, which does not look like a sha"
        end

        check_pr_head(sha)
        view
      end

      def existing_or_new_pull_request
        view = refusing { @git_pr.open_pull_request(@branch) }
        if view
          puts "PR ##{view[:number]} already open for #{@branch} — not re-creating"
          return view
        end

        create_pull_request
        view = refusing { @git_pr.open_pull_request(@branch) }
        abort "gh pr create returned, but gh pr view #{@branch} shows no open PR — record nothing" unless view
        view
      end

      # The PR must carry the fix commit, whether this run opened it or an earlier one did.
      def check_pr_head(sha)
        return unless @bug

        refusing { @git_pr.assert_pr_head!(head: sha, commit: @bug.commit.to_h[:value].to_s, owner: @bug.id) }
      end

      def create_pull_request
        @git_pr.create_pull_request(branch: @branch, title: @options[:title], body: pull_request_body,
                                    draft: dial(:DRAFT_ONLY, false))
      rescue Hecks::Adapters::GitPr::CommandFailed => e
        abort e.message
      end

      # The body names the ledger record so the PR and the ledger point at each other.
      def pull_request_body
        @options[:body] ||
          "#{cited_record}\n\nOpened by hecks quality_control patch.open and recorded in the QualityControl ledger."
      end

      def cited_record
        return "Fixes #{@bug.id}." if @bug
        return "Builds #{@angle.id}." if @angle

        "Deliberate work, no Bug or Angle behind it."
      end
    end
  end
end
