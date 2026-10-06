# frozen_string_literal: true

require "English"
require "pathname"
require_relative "../../tools"
require_relative "source_file"
require_relative "baseline"
require_relative "dictionary"

module Hecks
  module Tools
    module CommentStyle
      # Lints a set of paths and renders the result.
      class Run
        # @param paths [Array<String>] files or directories
        # @param only [Array<String>, nil] categories to keep
        # @param baseline [Hash{String => Hash{String => Integer}}] the long blocks to tolerate
        def initialize(paths, only: nil, baseline: Baseline.load)
          @files = paths.flat_map { |p| File.directory?(p) ? ruby_files(p) : [p] }.sort.uniq
          @only = only
          @baseline = baseline
        end

        # Every block over `MAX_BLOCK` lines in these files, in the baseline's own shape.
        #
        # @return [Hash{String => Hash{String => Integer}}] file path to block key to length
        def long_block_baseline
          @files.each_with_object({}) do |path, held|
            blocks = SourceFile.new(path).long_blocks
            held[path.delete_prefix("./")] = blocks.to_h { |block| [block.key, block.lines] } if blocks.any?
          end
        end

        # Files whose code differs from `ref`, comments and whitespace aside.
        #
        # A file `ref` does not hold (new since `ref`, or outside the repository) counts as
        # changed: what cannot be compared is not vouched for.
        #
        # @param ref [String] revision to compare the working tree against
        # @return [Array<String>] paths whose non-comment token stream changed
        # @raise [ArgumentError] when `ref` names no commit
        def code_changed_since(ref)
          top = vcs_output("rev-parse", "--show-toplevel", chdir: Dir.pwd)&.strip
          raise ArgumentError, "not inside a checkout" if top.nil? || top.empty?
          unless vcs_output("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: top)
            raise ArgumentError, "unknown ref #{ref.inspect}"
          end

          @files.select do |path|
            before = committed_source(ref, path, top)
            before.nil? || CommentStyle.code_tokens(before) != CommentStyle.code_tokens(File.read(path))
          end
        end

        # Every violation across the whole file set, computed once.
        #
        # @return [Array<Violation>]
        def violations
          @violations ||= begin
            sources = @files.map { |path| SourceFile.new(path) }
            found = sources.flat_map { |source| source.violations(only: @only, baseline: @baseline) } +
                    undocumented_types(sources)
            @only ? found.select { |v| @only.include?(v.category) } : found
          end
        end

        # Rewrites every file's fixable categories in place.
        #
        # @return [Integer] number of files rewritten
        def fix!
          wants_caps = @only.nil? || @only.include?("all_caps")
          abort "fixing all_caps needs the word list at #{Dictionary::WORDS}" if wants_caps && !Dictionary.words

          @files.count do |path|
            original = File.read(path)
            output = SourceFile.new(path, original).fixed(only: @only)
            next false if output == original

            File.write(path, output)
            true
          end
        end

        # Renders the summary tables `--report` prints.
        #
        # @param top [Integer] rows to show in the per-file table
        # @return [String]
        def report(top: 20)
          by_file = violations.group_by(&:path)
          [
            "#{violations.size} violations in #{by_file.size} of #{@files.size} files\n",
            "By category:", *category_rows,
            "\nBy directory (top #{top}):", *directory_rows.first(top),
            "\nWorst #{top} files:", *file_rows(by_file, top)
          ].join("\n")
        end

        private

        # `path`'s text at `ref`, or nil when the repository at `top` holds none there.
        def committed_source(ref, path, top)
          relative = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(top)).to_s
          return nil if relative == ".." || relative.start_with?("../")

          vcs_output("show", "#{ref}:#{relative}", chdir: top)&.force_encoding(Encoding::UTF_8)
        end

        # What `git <args>` printed, or nil when it failed.
        def vcs_output(*args, chdir:)
          out = IO.popen(["git", *args], chdir: chdir, err: File::NULL, &:read)
          $CHILD_STATUS.success? ? out : nil
        end

        # `.rb` files, plus extensionless scripts with a Ruby shebang. The first line is read as
        # bytes, so an extensionless binary (a compiled test fixture's output) is passed over
        # rather than refused for not being UTF-8.
        def ruby_files(dir)
          scripts = Dir[File.join(dir, "**", "*")].select do |path|
            File.file?(path) && File.extname(path).empty? && File.open(path, "rb", &:gets).to_s.match?(/\A#!.*ruby/n)
          end
          Dir[File.join(dir, "**", "*.rb")] + scripts
        end

        def category_rows
          counts = violations.group_by(&:category).transform_values(&:size)
          CATEGORIES.map do |name, description|
            suffix = FIXABLE.include?(name) ? " [fixable]" : ""
            "  #{counts.fetch(name, 0).to_s.rjust(6)}  #{name.ljust(24)} #{description}#{suffix}"
          end
        end

        def directory_rows
          violations.group_by { |v| v.path.split("/")[0, 3].join("/") }
                    .sort_by { |_, list| -list.size }
                    .map { |dir, list| "  #{list.size.to_s.rjust(6)}  #{dir}" }
        end

        def file_rows(by_file, top)
          by_file.sort_by { |_, list| -list.size }.first(top).map do |file, list|
            category, worst = list.group_by(&:category).max_by { |_, group| group.size }
            "  #{list.size.to_s.rjust(6)}  #{file}  (mostly #{category}: #{worst.size})"
          end
        end

        # A type reopened across files counts as documented if any opening is.
        def undocumented_types(sources)
          openings = sources.flat_map { |s| s.types.reject(&:namespace_only).map { |t| [s, t] } }
          openings.group_by { |_, type| type.fqn }.filter_map { |fqn, group| undocumented_opening(fqn, group) }
        end

        def undocumented_opening(fqn, group)
          return unless CommentStyle.public_surface.include?(fqn.to_s.split("::").last)
          return if group.any? { |source, type| source.documented?(type) }

          source, type = group.first
          Violation.new(source.path, type.line, "undocumented_class", fqn)
        end
      end
    end
  end
end
