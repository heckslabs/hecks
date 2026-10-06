# frozen_string_literal: true

require_relative "qa_discover_external_domains/parsing"
require_relative "qa_discover_external_domains/scanning"
require_relative "qa_discover_external_domains/reporting"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.discover_external_domains`: reports
    # sibling-repo bluebook domains under `--projects-dir` that already depend on the hecks gem but
    # are not enrolled yet. It never enrolls anything itself.
    #
    #   hecks quality_control target.discover_external_domains
    #   hecks quality_control target.discover_external_domains --projects-dir ~/Projects
    #   hecks quality_control target.discover_external_domains --max-depth 4
    #   hecks quality_control target.discover_external_domains --known-path <path> ...   # bypass
    # the ledger read
    class QaDiscoverExternalDomains
      include Parsing
      include Scanning
      include Reporting

      USAGE = "usage: hecks quality_control discover_external_domains [--projects-dir <path>] " \
              "[--max-depth N] [--known-path <path> ...]"

      DEFAULT_PROJECTS_DIR = File.expand_path("~/Projects").freeze
      DEFAULT_MAX_DEPTH = 3

      # Skipped everywhere in a sibling repo: VCS internals, vendored dependency trees, and this
      # repo's own worktree scratch space.
      SKIP_DIR_BASENAMES = %w[.git .hg .svn vendor node_modules .bundle tmp log coverage .yardoc .ruby-lsp
                              .parked bower_components .claude dist build].freeze

      # Word-boundary matched so a near-miss gem name (a separate gem) and "hecks_site" never
      # false-positive as a hecks dependency.
      GEMFILE_PATTERN = /gem\s*\(?\s*["']hecks["']/
      GEMFILE_LOCK_PATTERN = /^\s+hecks\s+\(/

      # Raised for a wrong command line or an unreadable ledger; it ends the run with status 1.
      class Refused < StandardError
        # @return [Boolean] whether the usage line follows the message
        attr_reader :usage

        # @param message [String] why the run stopped
        # @param usage [Boolean] whether the usage line follows the message
        def initialize(message, usage: true)
          super(message)
          @usage = usage
        end
      end

      # Reports the candidates.
      #
      # @param argv [Array<String>] `--projects-dir`, `--max-depth` and `--known-path`
      # @param root [String] the repository root
      # @return [Integer] 0 once reported, 1 for a usage error or an unreadable ledger
      def self.call(argv, root:)
        new(root: root).call(argv)
      end

      # @param root [String] the repository root
      def initialize(root:)
        @root = root
      end

      # @param argv [Array<String>] `--projects-dir`, `--max-depth` and `--known-path`
      # @return [Integer] the exit status
      def call(argv)
        options = parse(argv.dup)
        return 0 if options == :help

        candidates, skipped, siblings = discover(options)
        report(options, candidates, skipped, siblings)
        0
      rescue Refused => e
        warn e.message
        warn USAGE if e.usage
        1
      end

      private

      # @return [Array(Array<Hash>, Array<String>, Array<String>)] the candidates, the siblings
      #   with no hecks dependency, and every sibling scanned
      def discover(options)
        known = known_path_set(options)
        siblings = sibling_repos(options[:projects_dir])
        candidates = []
        skipped = []
        siblings.each do |repo_path|
          entities = hecks_entities(repo_path, options[:max_depth])
          skipped << repo_path if entities.empty?
          candidates.concat(unenrolled(repo_path, entities, known))
        end
        [candidates.sort_by { |c| [c[:repo], c[:reference]] }, skipped, siblings]
      end

      # Ledger paths may be stored root-relative or absolute; normalize both to compare.
      def known_path_set(options)
        known_raw = options[:known_paths] || ledger_target_paths
        known_raw.to_set { |path| File.expand_path(path, @root) }
      end

      def hecks_entities(repo_path, max_depth)
        bluebook_shaped_dirs(repo_path, max_depth).select do |entity_dir, _entity_name|
          depends_on_hecks_anywhere_above?(entity_dir, repo_path)
        end
      end

      def unenrolled(repo_path, entities, known)
        repo_name = File.basename(repo_path)
        entities.filter_map do |entity_dir, entity_name|
          absolute = File.expand_path(entity_dir)
          next if known.include?(absolute)

          { repo: repo_name, reference: "#{repo_name}/#{entity_name}", path: absolute }
        end
      end
    end
  end
end
