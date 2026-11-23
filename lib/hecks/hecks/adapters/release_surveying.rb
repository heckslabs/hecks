# frozen_string_literal: true

require "hecks/release/runner"
require "hecks/release/lane"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Surveying` port's adapter for `NextRelease`: reads, from git and the `Lane` row a release
    # is cut from, the facts the bluebook weighs, and judges none of them.
    #
    # The facts are how many commits `origin/stable` holds that no tag covers (a release's own bump
    # commit is not one), how many whole days the oldest has stood there (the clock is read here,
    # never in the bluebook), whether the version on `stable` has no tag yet (a bump is waiting for
    # its release), whether the changes added a command, aggregate, value object, event or policy,
    # and whether any carries a translation edge, a shape change the ledger does not pass as
    # additive. The two soak settings are the `Lane` row's.
    class ReleaseSurveying
      # What a bump commit's subject starts with; such a commit is the release, not a change to it.
      RELEASE_SUBJECT = /\ARelease v?\d/

      # Added lines of a bluebook that declare a new piece of the domain.
      ADDED_CONCEPT = /^\+\s*(aggregate|command|value_object|event|policy|feature)\b/

      SECONDS_A_DAY = 86_400

      # Where `lib/hecks/version.rb` declares the version.
      VERSION_DECLARATION = /VERSION = "([^"]+)"/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `root:` the checkout, `clock:` a call giving the seconds, `commands:`
      #   as `Release::Runner::Commands` runs processes
      # @param root [String, nil] the checkout when `settings` names none
      # @param registry [Runtime::Registry, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @root = settings[:root] || root || Dir.pwd
        @clock = settings[:clock] || -> { Time.now.to_i }
        @git = Release::Runner::Git.new(root: @root, commands: settings[:commands] || Release::Runner::Commands.new)
      end

      # The `Survey` ask.
      #
      # @return [Hash{Symbol => Hash}] each fact as a value object
      # @raise [ConsoleCapture::Failure] when git cannot answer
      def survey(**)
        lane = Release::Lane.release
        @git.read("fetch", "origin", "--tags", "--quiet")
        tip = "origin/#{lane}"
        tag = latest_tag(tip)
        facts(tip, tag).merge(settings(lane))
      rescue Release::Runner::Refusal => e
        raise ConsoleCapture::Failure, e.message
      end

      private

      def facts(tip, tag)
        changes = unreleased(tip, tag)
        names = tag.empty? ? [] : @git.read("diff", "--name-only", "#{tag}..#{tip}").lines
        { unreleased: value(changes.size), oldest_days: value(age_days(changes)),
          bump_pending: value(bump_pending?(tip)), non_additive: value(names.any? { |n| n.include?("/translations/") }),
          added_surface: value(added_surface?(tip, tag)) }
      end

      # The commits first-parent since the tag, oldest last, with their times.
      def unreleased(tip, tag)
        range = tag.empty? ? tip : "#{tag}..#{tip}"
        rows = @git.read("log", "--first-parent", "--format=%ct\t%s", range).lines.map { |line| line.chomp.split("\t", 2) }
        rows.reject { |_time, subject| subject.to_s.match?(RELEASE_SUBJECT) }.map { |time, _| time.to_i }
      end

      def age_days(times) = times.empty? ? 0 : (@clock.call - times.min) / SECONDS_A_DAY

      def latest_tag(tip)
        result = @git.capture("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", tip)
        result.success? ? result.stdout.strip : ""
      end

      def bump_pending?(tip)
        text = @git.read("show", "#{tip}:lib/hecks/version.rb")
        version = text[VERSION_DECLARATION, 1]
        !@git.capture("rev-parse", "-q", "--verify", "refs/tags/v#{version}").success?
      end

      def added_surface?(tip, tag)
        return false if tag.empty?

        diff = @git.read("diff", "-U0", "#{tag}..#{tip}", "--", "*.bluebook")
        diff.match?(ADDED_CONCEPT)
      end

      def settings(lane)
        row = Hecks::Vocabulary.rows("Lane").find { |each| each["name"] == lane }
        { soak_days: value(row["soak_days"].to_i), major_soak_days: value(row["major_soak_days"].to_i) }
      end

      def value(fact) = { value: fact }
    end
  end
end
