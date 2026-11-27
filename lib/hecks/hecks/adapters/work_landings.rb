# frozen_string_literal: true

require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    # The `WorkLandings` port's adapter for `Tickets::Work`: finds a landing of a work item's
    # branch that is on main.
    #
    # A work item's key is its branch's name. The candidates are the branch's tip, local or on
    # `origin`, the merges on `main` whose subject names the branch (`Merge branch 'key'`,
    # `Merge pull request #12 from owner/key`), and the commits on `main` that carry a
    # `Work: key` trailer (a squash that brought the branch in); the first one `main` contains is
    # the landing. A key written in prose names nothing. It states
    # the fact and judges nothing: closing the item is the Tickets bluebook's. It reads git and never
    # writes.
    class WorkLandings
      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `root:` the checkout whose `main` is read (the working directory
      #   when absent)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @checkout = settings[:root]
        @git = Git.new
      end

      # @param held [Hash] the Work item: `work`
      # @return [Hash{Symbol => Hash}] `landing:` the landed commit `main` contains
      # @raise [ConsoleCapture::Failure] naming the work item when no landing of it is on main
      def check_landing(**held)
        key = held[:work].is_a?(Hash) ? held[:work][:value].to_s : held[:work].to_s
        found = candidates(key).find { |sha| on_main?(sha) }
        raise ConsoleCapture::Failure, refusal(key) unless found

        { landing: { value: found } }
      end

      private

      # A key that is not a plain ref name names no branch and is looked for in no message.
      def candidates(key)
        return [] unless key.match?(GitRefs::REF_PATTERN)

        (tips(key) + mentions(key)).uniq
      end

      def tips(key)
        ["refs/heads/#{key}", "refs/remotes/origin/#{key}"].filter_map do |ref|
          found = @git.capture("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", chdir: @checkout)
          found.out.strip if found.ok? && !found.out.strip.empty?
        end
      end

      def mentions(key) = merges(key) | trailered(key)

      # The merges on main whose subject names the branch.
      def merges(key)
        branch = Regexp.escape(key)
        named = %r{\AMerge (?:(?:remote-tracking )?branch '(?:origin/)?#{branch}'|pull request #\d+ from [^/\s]+/#{branch}\z)}
        listed = @git.capture("log", "main", "--merges", "--format=%H%x00%s", chdir: @checkout)
        return [] unless listed.ok?

        listed.out.lines.filter_map do |line|
          sha, subject = line.chomp.split("\x00", 2)
          sha if subject&.match?(named)
        end
      end

      # The commits on main whose message carries a `Work: key` trailer.
      def trailered(key)
        listed = @git.capture("log", "main", "--format=%H%x00%B%x01", "--fixed-strings", "--grep=Work: #{key}",
                              chdir: @checkout)
        return [] unless listed.ok?

        trailer = /^Work: #{Regexp.escape(key)}\s*$/
        listed.out.split("\x01").filter_map do |entry|
          sha, message = entry.strip.split("\x00", 2)
          sha if message&.match?(trailer)
        end
      end

      def on_main?(sha) = @git.ancestor?(sha, "main", chdir: @checkout)

      def refusal(key)
        "#{key} has no landing on main: land its branch, or finish it with no_change.value=<why> " \
          "when it lands nothing"
      end
    end
  end
end
