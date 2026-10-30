# frozen_string_literal: true

require "json"
require "open3"

module Hecks
  module QualityControlCli
    class QaDiscoverExternalDomains
      # What `target.discover_external_domains` reads from disk: the sibling repos, the
      # bluebook-shaped directories inside them, whether each depends on the hecks gem, and the
      # ledger's known targets.
      module Scanning
        private

        def depends_on_hecks?(dir)
          gemfile = File.join(dir, "Gemfile")
          lockfile = File.join(dir, "Gemfile.lock")

          (File.file?(gemfile) && File.read(gemfile).match?(GEMFILE_PATTERN)) ||
            (File.file?(lockfile) && File.read(lockfile).match?(GEMFILE_LOCK_PATTERN))
        end

        # A monorepo's real hecks-dependent Ruby app can live below the sibling repo's own top
        # level (a nested `Gemfile` there, not one at `repo_root`). Checked against the candidate's
        # own directory first, then each ancestor up to and including `repo_root`, so the common
        # case, the dependency declared at `repo_root` itself, still answers exactly as it always
        # has.
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
          collect_entity_dirs(repo_root, 0, max_depth, found)
          found
        end

        def collect_entity_dirs(dir, depth, max_depth, found)
          entity_name = File.basename(dir)
          found << [dir, entity_name] if File.file?(File.join(dir, "bluebook", "#{entity_name}.bluebook"))
          return if depth >= max_depth

          descendable_children(dir).each { |path| collect_entity_dirs(path, depth + 1, max_depth, found) }
        end

        # The bluebook/ directory itself is never an entity dir.
        def descendable_children(dir)
          children_of(dir).filter_map do |child|
            next if SKIP_DIR_BASENAMES.include?(child) || child == "bluebook"

            path = File.join(dir, child)
            path if real_directory?(path)
          end
        end

        def real_directory?(path)
          File.directory?(path) && !File.symlink?(path)
        end

        def children_of(dir)
          Dir.children(dir).sort
        rescue Errno::EACCES, Errno::ENOENT
          []
        end

        # Shells out rather than booting the ledger in-process, so this is safe to run alongside a
        # live qa_tick or qa_sweep.
        def ledger_target_paths
          out, err, status = Open3.capture3("bundle", "exec", "ruby", File.join(@root, "exe/hecks"),
                                            "run", "qa/bluebook", "ask", "target.all", chdir: @root)
          unless status.success?
            raise Refused, "hecks quality_control discover_external_domains: could not read the ledger's targets " \
                           "(hecks run qa/bluebook ask target.all exited #{status.exitstatus}):\n#{err}\n" \
                           "pass --known-path <path> ... to run without the ledger", usage: false
          end

          JSON.parse(out).filter_map { |row| row.dig("path", "value") }
        end

        # The sibling directories under `projects_dir`, leaving out this repo (already fully covered
        # by existing seeding) and symlinks.
        def sibling_repos(projects_dir)
          root = checkout_root
          Dir.children(projects_dir).sort.filter_map do |child|
            next if child == "hecks"

            path = File.join(projects_dir, child)
            path if real_directory?(path) && !same_checkout?(path, root)
          end
        end

        def checkout_root
          File.realpath(@root)
        rescue Errno::ENOENT
          @root
        end

        # A path that vanished mid-scan counts as the checkout, so it is skipped.
        def same_checkout?(path, root)
          File.realpath(path) == root
        rescue Errno::ENOENT
          true
        end
      end
    end
  end
end
