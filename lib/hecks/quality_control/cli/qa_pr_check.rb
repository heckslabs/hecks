# frozen_string_literal: true

require_relative "../../../hecks"
# The ledger's `persisted_by "PostgresEra"` binding needs the era plugin, which core does not load.
require_relative "../../ports/persistence/plugins/era"
require_relative "../adapters/git_pr"
require_relative "qa_pr_check/checking"
require_relative "qa_pr_check/reporting"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control clearance.check_pull_requests`: checks CI for every
    # PR the QualityControl ledger tracks as open (`Patch` and `Improvement`). It starts a
    # `Clearance` per unsettled head commit and lets the CI port's policies record the verdict.
    #
    # Exit codes: 0 nothing to act on; 1 operational error (`gh`, bad sha, ledger boot);
    # 2 a newly red PR, with the details on stdout. A commit's `Clearance` is minted once and never
    # re-asked; pending checks are skipped, since the CI port has no way to say "ask again later".
    class QaPrCheck
      include Checking
      include Reporting

      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_NEWLY_RED = 2

      USAGE = "usage: hecks quality_control check_pull_requests"

      SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

      # Two worklists, checked the same way. The citation is what a row references: a `Bug` for a
      # `Patch`, an optional `Angle` for an `Improvement`.
      WORKLISTS = [
        { aggregate: "Patch", citation_field: :bug, citation_label: "bug" },
        { aggregate: "Improvement", citation_field: :angle, citation_label: "angle" }
      ].freeze

      # Checks every tracked PR.
      #
      # @param argv [Array<String>] no arguments; `--help` prints the usage
      # @param root [String] the repository root, where the ledger's boot directory is found
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` points at another ledger
      # @return [Integer] 0 clean, 1 on an operational error, 2 for a newly red PR
      # @raise [SystemExit] when given arguments, or the ledger does not boot
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` points at another ledger
      def initialize(root:, env: ENV)
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
      end

      # @param argv [Array<String>] no arguments; `--help` prints the usage
      # @return [Integer] the exit status
      # @raise [SystemExit] when given arguments, or the ledger does not boot
      def call(argv)
        return reject_arguments(argv) unless argv.empty?

        # Every `gh` call goes through the `GitPr` adapter. With `--json`, gh exits 0 whatever the
        # checks say, so a failure means only that the call did not succeed.
        @git_pr = Hecks::Adapters::GitPr.new(repo_dir: Dir.pwd)
        @runtime = boot_ledger
        worklists = WORKLISTS.to_h { |w| [w, query("#{w[:aggregate]}.Open")] }
        return nothing_to_check if worklists.values.all?(&:empty?)

        check_all(worklists)
      end

      private

      def reject_arguments(argv)
        if %w[-h --help].include?(argv.first)
          puts USAGE
          return EXIT_OK
        end
        abort "#{USAGE}\nthis script takes no arguments — it checks every PR QualityControl::Patch or " \
              "QualityControl::Improvement tracks as open, every time"
      end

      def nothing_to_check
        puts "no PRs tracked as open by QualityControl::Patch or QualityControl::Improvement — nothing to check"
        EXIT_OK
      end

      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot — fix the ledger itself before checking PRs against it " \
              "(#{e.class}: #{e.message})"
      end

      def check_all(worklists)
        @newly_red = []
        @operational_errors = []
        worklists.each do |worklist, rows|
          rows.each { |row| check_one_pr(row, **worklist) }
        end
        report_errors
        return report_newly_red if @newly_red.any?
        return EXIT_ERROR if @operational_errors.any?

        report_clean
      end

      def query(name, **args) = @runtime.query("QualityControl::#{name}", **args)

      # Reads nested row fields by `[]`, because `Hecks::Runtime::Value` does not answer `Hash#dig`.
      def field(row, *path)
        path.reduce(row) { |held, key| held.nil? ? nil : held[key] }
      end
    end
  end
end
