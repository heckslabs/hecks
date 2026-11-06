# frozen_string_literal: true

require "json"
require "open3"
require_relative "../../quality_control/adapters/main_ci_reader"

module Hecks
  module Adapters
    # Whether main is red, read from CI itself and not from a Work row some tick may not have filed.
    #
    # The latest FINISHED `CI` run on origin/main that concluded failure or success decides: failure
    # is red, success is clear. A cancelled or skipped run says nothing, and a run still going is not
    # read at all, so it never clears a red one; only a finished success on the head or a later head
    # does. `gh` that fails, or is not signed in, makes the state unknown, and an unknown state stops
    # nothing: every user of it says so in one line ({UNKNOWN}).
    #
    # The answer is cached in the repository's common git directory for the world's `red_main_stop`
    # `cache_minutes`, so the train and the dispatch fill do not ask GitHub on every call. The stop is
    # on only where the Hecks world declares `red_main_stop`; without it the state is `:off`.
    class RedMain
      # The world verb that switches the stop on and carries `cache_minutes:`.
      VERB = "red_main_stop"

      # Minutes a GitHub answer is kept when the world gives none.
      CACHE_MINUTES = 5

      # The cache's file, in the repository's common git directory.
      CACHE_FILE = "hecks-red-main.json"

      # The one line every user of an unknown state says.
      UNKNOWN = "main CI state unknown: gh failed; stop not applied"

      # What a finished run's conclusion means for the state; any other conclusion is ignored.
      DECIDING = %w[failure success].freeze

      # The state: `kind` is `:red`, `:clear`, `:unknown` or `:off`; `run` is the failing run when red.
      State = Struct.new(:kind, :run, keyword_init: true) do
        def red? = kind == :red
        def unknown? = kind == :unknown

        # @return [String] the line that leads a report: the stop, the unknown notice, or ""
        def lead
          return "STOP: main is red since #{run.created_at} (#{run.failed_job}): only fixes go out\n" if red?

          unknown? ? "#{UNKNOWN}\n" : ""
        end
      end

      # @param registry [Runtime::Registry, nil] whose Hecks world declares `red_main_stop`
      # @param checkout [String, nil] a directory inside the repository; the current one when nil
      # @param reader [#runs!, nil] the GitHub port; `MainCiReader` when nil
      # @param clock [#now] where the cache's age is read from
      # @return [State]
      def self.state(registry, checkout: nil, reader: nil, clock: Time)
        new(registry, checkout: checkout, reader: reader, clock: clock).state
      end

      def initialize(registry, checkout: nil, reader: nil, clock: Time)
        @setting = registry&.world("Hecks")&.for_verb(VERB)
        @checkout = checkout || Dir.pwd
        @reader = reader || MainCiReader.new(chdir: @checkout)
        @clock = clock
      end

      # @return [State] `:off` when the world declares no stop, else the cached or a fresh reading
      def state
        return State.new(kind: :off) unless @setting

        cached || fresh
      end

      private

      def fresh
        found = decide(@reader.runs!)
        remember(found)
        found
      rescue MainCiReader::Unreadable
        State.new(kind: :unknown)
      end

      def decide(runs)
        run = runs.find { |candidate| DECIDING.include?(candidate.conclusion) }
        run&.conclusion == "failure" ? State.new(kind: :red, run: run) : State.new(kind: :clear)
      end

      def minutes = Float(@setting[:cache_minutes] || CACHE_MINUTES)

      def cached
        saved = JSON.parse(File.read(cache_path), symbolize_names: true)
        return unless @clock.now.to_f - saved[:at] < minutes * 60

        saved[:run] ? State.new(kind: :red, run: MainCiReader::Run.new(**saved[:run])) : State.new(kind: :clear)
      rescue SystemCallError, JSON::ParserError, TypeError, ArgumentError
        nil
      end

      def remember(found)
        run = found.run&.to_h
        File.write(cache_path, JSON.generate(at: @clock.now.to_f, run: run))
      rescue SystemCallError
        nil
      end

      def cache_path
        @cache_path ||= git_common_file
      end

      def git_common_file
        out, status = Open3.capture2("git", "-C", @checkout, "rev-parse", "--path-format=absolute", "--git-common-dir",
                                     err: File::NULL)
        raise Errno::ENOENT, "no git directory" unless status.success?

        File.join(out.strip, CACHE_FILE)
      end
    end
  end
end
