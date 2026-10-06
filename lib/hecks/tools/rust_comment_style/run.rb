# frozen_string_literal: true

require_relative "../../tools"
require_relative "source_file"
require_relative "tokenizer"

module Hecks
  module Tools
    module RustCommentStyle
      # Lints a set of paths and renders the result.
      class Run
        # @param paths [Array<String>] files or directories
        # @param only [Array<String>, nil] categories to keep
        def initialize(paths, only: nil)
          @files = paths.flat_map { |p| File.directory?(p) ? rust_files(p) : [p] }.sort.uniq
          @only = only
        end

        # Every violation across the whole file set, computed once.
        #
        # @return [Array<Violation>]
        def violations
          @violations ||= begin
            found = @files.flat_map { |path| SourceFile.new(path).violations(only: @only) }
            @only ? found.select { |v| @only.include?(v.category) } : found
          end
        end

        # Rewrites every file's fixable categories in place.
        #
        # @return [Integer] number of files rewritten
        def fix!
          if wants_caps? && !CommentStyle::Dictionary.words
            abort "fixing all_caps needs the word list CommentStyle::Dictionary uses"
          end

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

        def wants_caps?
          @only.nil? || @only.include?("all_caps")
        end

        def rust_files(dir)
          Dir[File.join(dir, "**", "*.rs")].reject { |p| p.include?("/target/") }
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
      end
    end
  end
end
