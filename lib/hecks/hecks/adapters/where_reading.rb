# frozen_string_literal: true

require "hecks"
require_relative "settings_reading"
require_relative "../../adapters/driven/worktree_overlay"
require_relative "../../adapters/driving/launcher_options"

module Hecks
  module Adapters
    # The `Where` port's adapter for `Checkout`: the store each bluebook of a checkout's domain
    # uses and why, the audience and environment with their reasons, and any overlay file this
    # worktree lacks. It reads and never writes.
    class WhereReading
      # The variable that names the environment a copy runs in.
      VARIABLE = "HECKS_ENVIRONMENT"

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # @param held [Hash] `domain`, a checkout directory (the current directory when absent)
      # @return [Hash{Symbol => String}] `text:` one line per fact, each with its reason
      def where(**held)
        directory = plain(held[:domain]) || Dir.pwd
        { text: lines(directory).join("\n") }
      end

      private

      def lines(directory)
        ["domain: #{directory}", *store_lines(directory), audience_line(directory), environment_line,
         *missing_line(directory)]
      end

      def store_lines(directory)
        SettingsReading.new.stores(directory).map { |label, value, source| "#{label}: #{value} (#{source})" }
      end

      def audience_line(directory)
        return "audience: maintainer (a hecks checkout holds this directory)" if Driving::LauncherOptions.maintainer?(directory)

        "audience: person (no hecks checkout holds this directory)"
      end

      def environment_line
        return "environment: #{ENV[VARIABLE]} (#{VARIABLE})" if ENV.key?(VARIABLE)

        "environment: default (#{VARIABLE} is not set)"
      end

      def missing_line(directory)
        borrowed = WorktreeBorrow.from(directory)
        return ["overlay files: the main checkout's at #{borrowed} (this worktree keeps none of its own)"] if borrowed

        main, files = WorktreeOverlay.gap(directory)
        return [] if files.empty?

        ["overlay files this worktree lacks: #{files.join(", ")} (from the main checkout at #{main})"]
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
