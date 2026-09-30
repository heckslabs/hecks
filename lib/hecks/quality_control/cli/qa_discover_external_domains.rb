# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module QualityControlCli
    # The command behind `bin/qa_discover_external_domains`: reports sibling-repo bluebook domains
    # under `--projects-dir` that already depend on the hecks gem but are not enrolled yet. It
    # never enrolls anything itself.
    #
    #   bin/qa_discover_external_domains
    #   bin/qa_discover_external_domains --projects-dir ~/Projects
    #   bin/qa_discover_external_domains --max-depth 4
    #   bin/qa_discover_external_domains --known-path <path> ...   # bypass the ledger read
    class QaDiscoverExternalDomains
      USAGE = "usage: hecks quality_control discover_external_domains [--projects-dir <path>] " \
              "[--max-depth N] [--known-path <path> ...]"

      DEFAULT_PROJECTS_DIR = File.expand_path("~/Projects").freeze
      DEFAULT_MAX_DEPTH = 3

      # Skipped everywhere in a sibling repo: VCS internals, vendored dependency trees, and this
      # repo's own worktree scratch space.
      SKIP_DIR_BASENAMES = %w[.git .hg .svn vendor node_modules .bundle tmp log coverage .yardoc .ruby-lsp
                              .parked bower_components .claude dist build].freeze

      # Word-boundary matched so "hecksagain" (a real, separate gem) and "hecks_site" never
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

      def parse(argv)
        options = { projects_dir: DEFAULT_PROJECTS_DIR, max_depth: DEFAULT_MAX_DEPTH, known_paths: nil }
        until argv.empty?
          case (arg = argv.shift)
          when "-h", "--help"
            puts USAGE
            return :help
          when "--projects-dir"
            refuse!("--projects-dir needs a path") if argv.empty?
            options[:projects_dir] = File.expand_path(argv.shift)
          when "--max-depth"
            refuse!("--max-depth needs a number") if argv.empty?
            options[:max_depth] = Integer(argv.shift)
          when "--known-path"
            refuse!("--known-path needs a path") if argv.empty?
            (options[:known_paths] ||= []) << File.expand_path(argv.shift)
          else
            refuse!("unexpected argument #{arg.inspect}")
          end
        end
        refuse!("--max-depth must be >= 0") if options[:max_depth].negative?
        refuse!("#{options[:projects_dir]} is not a directory") unless File.directory?(options[:projects_dir])
        options
      end

      def refuse!(message)
        raise Refused, message
      end

      def depends_on_hecks?(dir)
        gemfile = File.join(dir, "Gemfile")
        lockfile = File.join(dir, "Gemfile.lock")

        (File.file?(gemfile) && File.read(gemfile).match?(GEMFILE_PATTERN)) ||
          (File.file?(lockfile) && File.read(lockfile).match?(GEMFILE_LOCK_PATTERN))
      end

      # A monorepo's real hecks-dependent Ruby app can live below the sibling repo's own top level
      # (a nested `Gemfile` there, not one at `repo_root`). Checked against the candidate's own
      # directory first, then each ancestor up to and including `repo_root`, so the common case, the
      # dependency declared at `repo_root` itself, still answers exactly as it always has.
      def depends_on_hecks_anywhere_above?(entity_dir, repo_root)
        root = File.expand_path(repo_root)
        dir = File.expand_path(entity_dir)
        loop do
          return true if depends_on_hecks?(dir)
          return false if dir == root

          parent = File.dirname(dir)
          return false if parent == dir # filesystem root reached without finding repo_root

          dir = parent
        end
      end

      # `repo_root` itself is depth 0, so a project that is one domain at its own top can be a
      # candidate too.
      def bluebook_shaped_dirs(repo_root, max_depth)
        found = []
        walk = lambda do |dir, depth|
          entity_name = File.basename(dir)
          found << [dir, entity_name] if File.file?(File.join(dir, "bluebook", "#{entity_name}.bluebook"))
          return if depth >= max_depth

          children_of(dir).each do |child|
            next if SKIP_DIR_BASENAMES.include?(child)

            child_path = File.join(dir, child)
            next unless File.directory?(child_path) && !File.symlink?(child_path)
            next if child == "bluebook" # the bluebook/ directory itself is never an entity dir

            walk.call(child_path, depth + 1)
          end
        end
        walk.call(repo_root, 0)
        found
      end

      def children_of(dir)
        Dir.children(dir).sort
      rescue Errno::EACCES, Errno::ENOENT
        []
      end

      # Shells out rather than booting the ledger in-process, so this is safe to run alongside a
      # live qa_tick or qa_sweep.
      def ledger_target_paths
        out, err, status = Open3.capture3("bundle", "exec", "ruby", File.join(@root, "bin/run"),
                                          "qa/bluebook", "ask", "target.all", chdir: @root)
        unless status.success?
          raise Refused, "bin/qa_discover_external_domains: could not read the ledger's targets " \
                         "(bin/run qa/bluebook ask target.all exited #{status.exitstatus}):\n#{err}\n" \
                         "pass --known-path <path> ... to run without the ledger", usage: false
        end

        JSON.parse(out).filter_map { |row| row.dig("path", "value") }
      end

      def sibling_repos(projects_dir)
        hecks_root = begin
          File.realpath(@root)
        rescue Errno::ENOENT
          @root
        end
        Dir.children(projects_dir).sort.filter_map do |child|
          next if child == "hecks" # this repo, already fully covered by existing seeding

          path = File.join(projects_dir, child)
          next unless File.directory?(path) && !File.symlink?(path)

          begin
            next if File.realpath(path) == hecks_root
          rescue Errno::ENOENT
            next
          end

          path
        end
      end

      # @return [Array(Array<Hash>, Array<String>, Array<String>)] the candidates, the siblings
      #   with no hecks dependency, and every sibling scanned
      def discover(options)
        known_raw = options[:known_paths] || ledger_target_paths
        # Ledger paths may be stored root-relative or absolute; normalize both to compare.
        known = known_raw.to_set { |path| path.start_with?("/") ? File.expand_path(path) : File.expand_path(path, @root) }
        siblings = sibling_repos(options[:projects_dir])
        candidates = []
        skipped = []
        siblings.each do |repo_path|
          found = false
          bluebook_shaped_dirs(repo_path, options[:max_depth]).each do |entity_dir, entity_name|
            next unless depends_on_hecks_anywhere_above?(entity_dir, repo_path)

            found = true
            absolute = File.expand_path(entity_dir)
            next if known.include?(absolute)

            repo_name = File.basename(repo_path)
            candidates << { repo: repo_name, reference: "#{repo_name}/#{entity_name}", path: absolute }
          end
          skipped << repo_path unless found
        end
        [candidates.sort_by { |c| [c[:repo], c[:reference]] }, skipped, siblings]
      end

      def report(options, candidates, skipped, siblings)
        puts "scanned #{siblings.size} sibling(s) under #{options[:projects_dir]} " \
             "(max depth #{options[:max_depth]}), #{siblings.size - skipped.size} depend on the hecks gem"
        puts "no hecks dependency, skipped: #{skipped.map { |p| File.basename(p) }.join(', ')}" unless skipped.empty?
        puts
        if candidates.empty?
          puts "no new candidates — every hecks-dependent sibling's bluebook-shaped domain is either " \
               "already a Target or none was found in the shape <name>/bluebook/<name>.bluebook within " \
               "--max-depth #{options[:max_depth]}."
          return
        end

        puts "#{candidates.size} candidate(s) — report only, nothing identified. Review each, then run " \
             "the command yourself to enroll it:"
        puts
        candidates.each do |c|
          puts "  #{c[:reference]}"
          puts "    path: #{c[:path]}"
          puts "    enroll: bin/run qa/bluebook identify reference=#{c[:reference]} path=#{c[:path]}"
          puts
        end
      end
    end
  end
end
