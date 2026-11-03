# frozen_string_literal: true

require "open3"
require "pathname"
require "yaml"
require_relative "../gate_memo"

module Hecks
  module Tools
    module GateMemo
      # Decides how much of RuboCop a gate run needs. The green run's memo holds the hash of every
      # Ruby
      # file and of the configuration, and the run is skipped only when the files and their hashes
      # are
      # identical to it. Otherwise RuboCop lints the changed files and the files that require them,
      # and
      # a full run is made whenever that set cannot be worked out.
      module RubyFiles
        # Files whose change invalidates every verdict: the configuration and the local cops it
        # loads.
        CONFIG = %w[.rubocop.yml .rubocop_todo.yml Gemfile.lock lib/rubocop/cop/**/*.rb].freeze

        # A `require` or `require_relative` line, and the path it names.
        REQUIRE = /^\s*require(_relative)?\s+["']([^"']+)["']/

        # Directories that hold Ruby the checkout does not own, or copies of it.
        SKIPPED_DIRS = %w[.claude .git rust vendor node_modules tmp].freeze

        module_function

        # @param root [String] the checkout
        # @return [Hash{String => String}] each Ruby file's path and sha256
        def hashes(root)
          listed(root).to_h { |rel| [rel, GateMemo.sha(root, rel)] }
        end

        # @return [Array<String>] the Ruby files of the checkout, sorted, the same set whether
        #   or not the checkout is a git repository
        def listed(root)
          listing(root).reject { |rel| rel.split("/").intersect?(SKIPPED_DIRS) }.sort
        end

        # @return [Array<String>] the Ruby files git lists, or the ones on disk when git does not
        def listing(root)
          out, status = Open3.capture2("git", "-C", root, "ls-files", "-co", "--exclude-standard", "--", "*.rb",
                                       err: File::NULL)
          return out.split("\n") if status.success?

          Dir.glob("**/*.rb", base: root)
        end

        # @param root [String] the checkout
        # @param entry [Hash, nil] the memo's entry for rubocop: `inputs` (the config's digest) and
        # `files`
        # @param now [Hash{String => String}] the checkout's Ruby files and their hashes, as they
        # are now
        # @return [Array(Symbol, Array<String>, String)] the mode (`skip`, `incremental` or `full`),
        # the
        #   files to lint when incremental, and why
        def plan(root, entry, now)
          return [:full, [], "no green run is recorded"] unless entry.is_a?(Hash) && entry["files"].is_a?(Hash)
          return [:full, [], "the configuration or a local cop changed"] unless entry["inputs"] == config(root)
          return [:skip, [], "the Ruby files are unchanged"] if now == entry["files"]

          incremental(root, entry["files"], now)
        rescue SystemCallError, EncodingError, ArgumentError => e
          [:full, [], "the Ruby files could not be read (#{e.message})"]
        end

        # @return [String] the digest of the configuration and the local cops
        def config(root) = GateMemo.fingerprint(root, CONFIG)

        # @return [Array(Symbol, Array<String>, String)] the files that changed, or were removed,
        # and the
        #   files that require them, less the ones `AllCops` Exclude names; skipped when only
        #   excluded files changed, and a full run when a removal leaves nothing to lint
        def incremental(root, was, now)
          changed = now.keys.reject { |rel| was[rel] == now[rel] }
          removed = was.keys - now.keys
          set = lintable(root, closure(root, changed + removed, now.keys))
          return nothing_to_lint(removed) if set.empty?

          [:incremental, set, "#{set.size} of #{now.size} Ruby files: changed, removed or requiring them"]
        end

        # @return [Array(Symbol, Array<String>, String)] a full run when a removal left the set
        #   empty, since an empty file list would make RuboCop lint the whole tree; otherwise a
        #   skip, because only excluded files changed
        def nothing_to_lint(removed)
          return [:full, [], "removed files leave nothing to lint"] if removed.any?

          [:skip, [], "only files the configuration excludes changed"]
        end

        # @return [Array<String>] the files that `AllCops` Exclude does not name, as RuboCop
        #   applies it to a full run; an explicit file list would otherwise bypass it
        def lintable(root, files)
          globs = excludes(root)
          files.reject { |rel| globs.any? { |glob| File.fnmatch?(glob, rel, File::FNM_PATHNAME) } }
        end

        # @return [Array<String>] the `AllCops` Exclude globs of the checkout's `.rubocop.yml`; none
        #   when the file is absent
        def excludes(root)
          path = File.join(root, ".rubocop.yml")
          return [] unless File.file?(path)

          Array(YAML.safe_load_file(path, permitted_classes: [Symbol]).dig("AllCops", "Exclude"))
        end

        # @return [Array<String>] the seeds and every file that requires one, through
        # require_relative
        #   and require "hecks/..." lines, among the files now present
        def closure(root, seeds, present)
          reverse = requirers(root, present)
          queue = seeds.dup
          seen = queue.to_set
          queue.shift.then { |rel| (reverse[rel] || []).each { |req| queue << req if seen.add?(req) } } until queue.empty?
          seen.select { |rel| present.include?(rel) }.sort
        end

        # @return [Hash{String => Array<String>}] each file's requirers, keyed by the file it
        # requires
        def requirers(root, present)
          present.each_with_object(Hash.new { |h, k| h[k] = [] }) do |rel, reverse|
            requires(root, rel).each { |target| reverse[target] << rel }
          end
        end

        # @return [Array<String>] the Ruby files that `rel` requires inside the checkout
        def requires(root, rel)
          source = File.read(File.join(root, rel))
          source.scan(REQUIRE).filter_map do |relative, name|
            relative ? resolve_relative(rel, name) : resolve_library(name)
          end
        end

        # @return [String] the path a `require_relative` names, from the file that names it
        def resolve_relative(rel, name)
          target = name.end_with?(".rb") ? name : "#{name}.rb"
          Pathname.new(File.join(File.dirname(rel), target)).cleanpath.to_s
        end

        # @return [String, nil] the library file a `require "hecks/x"` names under lib/; nil for a
        # gem
        def resolve_library(name)
          "lib/#{name}.rb" if name.start_with?("hecks/")
        end
      end
    end
  end
end
