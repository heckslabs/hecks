# frozen_string_literal: true

module Hecks
  module Adapters
    # Answers whether a raw `git`, `gh`, `grep`, `rg` or `find` call is on a role's read-only rows.
    # It holds no list: the rows (`RoutingRule` patterns that start with one of those words) and the
    # `ShellFlagRule` rows are handed in from the Agents bluebook.
    class ShellReads
      SHELL = /\A(?:git|gh|grep|rg|find)(?:\s|\z)/
      CLUSTER = /\A-[A-Za-z0-9]{2,}\z/
      LISTING = %w[--list --merged --no-merged].freeze

      # @param text [String] a command, stripped
      # @return [Boolean] whether the command is a git, gh, grep, rg or find call
      def self.shell?(text) = text.match?(SHELL)

      # @param patterns [Array<String>] a role's routing patterns
      # @param flags [Array<Hash>] its `ShellFlagRule` rows
      def initialize(patterns, flags)
        @rules = patterns.grep(SHELL).map(&:split)
        @flags = flags
      end

      # @param text [String] one git, gh, grep, rg or find call
      # @return [Boolean] whether a row names it and its flags pass the flag rows
      def allowed?(text)
        words = text.split
        rule = @rules.find { |candidate| words.first(candidate.size) == candidate }
        !rule.nil? && flags_ok?(rule, words.drop(rule.size))
      end

      private

      def flags_ok?(rule, args)
        flags = args.select { |word| word.start_with?("-") }.map { |word| word.split("=").first }
        return false if (flags | clustered(flags)).intersect?(listed(rule, :deny))

        allow = listed(rule, :allow, exact: true)
        allow.empty? || ((flags - allow).empty? && listing?(args, flags))
      end

      # The single letters of each short-flag cluster (`-zn` is `-z` and `-n`), so a denied short
      # flag is refused wherever it is written.
      def clustered(flags) = flags.grep(CLUSTER).flat_map { |word| word[1..].chars.map { |c| "-#{c}" } }

      # A call with a plain word (a name to create) is a listing only when a list flag is present.
      def listing?(args, flags) = args.all? { |word| word.start_with?("-") } || flags.intersect?(LISTING)

      def listed(rule, key, exact: false)
        names = exact ? [rule.join(" ")] : [rule.first, rule.join(" ")]
        @flags.select { |row| names.include?(row[:command]) }.flat_map { |row| row[key].to_s.split }
      end
    end
  end
end
