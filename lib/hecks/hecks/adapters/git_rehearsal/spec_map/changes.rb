# frozen_string_literal: true

require "open3"
require_relative "declarations"
require_relative "needles"

module Hecks
  module Adapters
    class GitRehearsal
      class SpecMap
        # The names a diff changed in a domain file: what a spec has to say to read the change.
        #
        # A world file changes a setting, so the names are the setting verb and the keys on the
        # changed lines (`dispatch_max_load`). A bluebook or hecksagon changes a declaration, so the
        # names are the declarations that enclose each changed hunk (`StallKind`, `StallWatch`) and
        # the qualified verbs a changed line names (`Finding.report!`). A path with no changed line,
        # or that is not a domain file, has none.
        class Changes
          HUNK = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/
          KEY = /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/
          VERB = /\b[A-Z]\w+\.[a-z_]+!?/
          SETTING = /\A\s*([a-z][a-z_0-9]*)\s/
          AGGREGATE_REF = /\b([A-Z][A-Za-z0-9]*)(?:::|\.)[A-Z]\w*/
          GENERIC = %w[Hecks].freeze
          MOST = 40
          CHANGED_LINE = /\A[+-](?![+-])/

          # @param root [String] the tree, a git work tree
          # @param since [String] the ref the changes are read against, the working tree included
          def initialize(root, since)
            @root = root
            @since = since
          end

          # @param paths [Array<String>] changed paths relative to the root
          # @return [Hash{String => Array<String>}] each domain path with changed lines, its names
          def names(paths)
            paths.grep(Needles::DOMAIN).to_h { |path| [path, read(path)] }
                 .reject { |_path, found| found.empty? }
          end

          private

          def read(path)
            hunks = diff(path).lines
            changed = hunks.grep(CHANGED_LINE).map { |line| line[1..] }
            found = changed.flat_map { |line| line_names(path, line) }
            (found + enclosing(path, hunks)).uniq.first(MOST)
          end

          def line_names(path, line)
            return [] if line.strip.start_with?("#") && !path.end_with?(".world")

            keys = line.scan(KEY) + line.scan(VERB) + [line[SETTING, 1]]
            path.end_with?(".world") ? keys.compact : aggregates(line) + line.scan(VERB)
          end

          # The aggregates a changed line names as `Agg.Event`, `Agg::Command` or `on "Agg.Event"`,
          # so a policy declared outside its aggregate still reaches the specs that name it. The
          # names a path yields are capped by `MOST` and the specs by the map's own limit.
          def aggregates(line) = line.scan(AGGREGATE_REF).flatten.uniq - GENERIC

          def enclosing(path, hunks)
            return [] if path.end_with?(".world")

            starts = hunks.filter_map { |line| line[HUNK, 1]&.to_i }
            lines = File.exist?(File.join(@root, path)) ? File.readlines(File.join(@root, path)) : []
            starts.flat_map { |start| Declarations.new(lines).around(start) }
          end

          def diff(path)
            out, status = Open3.capture2e("git", "-C", @root, "diff", "-U0", "--no-color", @since, "--", path)
            status.success? ? out : ""
          end
        end
      end
    end
  end
end
