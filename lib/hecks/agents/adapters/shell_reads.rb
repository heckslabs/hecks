# frozen_string_literal: true

module Hecks
  module Adapters
    # Answers whether a raw `git` or `gh` call is on a role's read-only rows. It holds no list: the
    # rows (`RoutingRule` patterns that start with `git ` or `gh `) and the `ShellFlagRule` rows are
    # handed in from the Agents bluebook.
    class ShellReads
      SHELL = /\A(?:git|gh)\s/
      LISTING = %w[--list --merged --no-merged].freeze

      # @param text [String] a command, stripped
      # @return [Boolean] whether the command is a git or gh call
      def self.shell?(text) = text.match?(SHELL)

      # @param patterns [Array<String>] a role's routing patterns
      # @param flags [Array<Hash>] its `ShellFlagRule` rows
      def initialize(patterns, flags)
        @rules = patterns.grep(SHELL).map(&:split)
        @flags = flags
      end

      # @param text [String] one git or gh call
      # @return [Boolean] whether a row names it and its flags pass the flag rows
      def allowed?(text)
        words = text.split
        rule = @rules.find { |candidate| words.first(candidate.size) == candidate }
        !rule.nil? && flags_ok?(rule, words.drop(rule.size))
      end

      private

      def flags_ok?(rule, args)
        flags = args.select { |word| word.start_with?("-") }.map { |word| word.split("=").first }
        return false if flags.intersect?(listed(rule, :deny))

        allow = listed(rule, :allow, exact: true)
        allow.empty? || ((flags - allow).empty? && listing?(args, flags))
      end

      # A call with a plain word (a name to create) is a listing only when a list flag is present.
      def listing?(args, flags) = args.all? { |word| word.start_with?("-") } || flags.intersect?(LISTING)

      def listed(rule, key, exact: false)
        names = exact ? [rule.join(" ")] : [rule.first, rule.join(" ")]
        @flags.select { |row| names.include?(row[:command]) }.flat_map { |row| row[key].to_s.split }
      end
    end
  end
end
