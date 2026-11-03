require "hecks/command_names"
require_relative "doc_staleness/sources"
require_relative "doc_staleness/markdown_scan"
require_relative "doc_staleness/comment_scan"

module Hecks
  # Reads docs and comments for citations that point at nothing: a repo path that is gone, a
  # `Hecks::` constant that is not defined, a `@param` tag the method does not take.
  module DocStaleness
    # The clean verdict.
    CLEAN = "every repo path, Hecks constant and @param tag a doc or comment cites still exists".freeze

    module_function

    # @param root [String] the checkout
    # @param paths [Array<String>] files or directories to read below `root`, or empty for all
    # @return [String] the clean verdict
    # @raise [Failure] with a `file:line: [class] reason` line for each stale citation
    def check(root:, paths: [])
      found = findings(root: root, paths: paths)
      raise Failure, found.join("\n") unless found.empty?

      CLEAN
    end

    # @return [Array<Finding>] every stale citation under `paths`, by file then line
    def findings(root:, paths: [])
      index = ConstantIndex.new(root)
      Sources.files(root, paths).flat_map { |path| scan(root, path, index) }
    end

    # @return [Array<Finding>] the stale citations in one file
    def scan(root, path, index)
      text = File.read(File.join(root, path), encoding: "UTF-8").scrub
      return [] if Sources.excused?(text)

      scanner = path.end_with?(".md") ? MarkdownScan : CommentScan
      scanner.new(root, path, text, index).findings
    end

    # Raised with every finding.
    class Failure < StandardError; end
  end
end
