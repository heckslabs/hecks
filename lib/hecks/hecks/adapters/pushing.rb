# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "pusher_marker"

module Hecks
  module Adapters
    # The `Pushing` port's adapter for `Pusher`: assigns the session that alone boards the push
    # train, says who it is, and lists the commits that landed on local main and wait to be pushed.
    # The assignment is `PusherMarker`'s file; nothing else is written.
    class Pushing
      # Separates a commit's fields and a commit from the one before it in `git log`'s output.
      FIELD = "\u001f"
      COMMIT = "\u001e"

      # The branch a merge commit's subject names: `Merge branch 'x'`.
      MERGED = /\AMerge branch '([^']+)'/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param tune [Hash] `checkout:` the repository (for a spec)
      def initialize(aggregate: nil, settings: {}, root: nil, **tune)
        @tune = tune
      end

      # @param held [Hash] the `Pusher` record: `session`, `checkout`
      # @return [Hash{Symbol => Hash}] `session:` the pusher now assigned
      def mark(**held)
        session = plain(held[:session]).to_s
        PusherMarker.new(git_dir(held)).assign!(session)
        { session: { value: session } }
      end

      # @param held [Hash] `checkout`
      # @return [Hash{Symbol => String}] `text:` the pusher in words, or that none is assigned
      def current(**held)
        pusher = PusherMarker.new(git_dir(held)).read
        { text: pusher.to_s.empty? ? "no pusher is assigned: any session may board\n" : "the pusher is #{pusher}\n" }
      end

      # @param held [Hash] `checkout`
      # @return [Hash{Symbol => String}] `text:` one entry per commit on local main the remote lacks
      def waiting(**held)
        log = capture(held, "log", "--reverse", "--name-only", "--format=#{COMMIT}%h#{FIELD}%an#{FIELD}%s", "origin/main..main")
        entries = commits(log).map { |entry| describe(entry) }
        { text: entries.empty? ? "nothing waits: local main is on origin\n" : "#{entries.join("\n")}\n" }
      end

      private

      def commits(log) = log.split(COMMIT).map(&:strip).reject(&:empty?)

      def describe(entry)
        head, *files = entry.lines.map(&:strip).reject(&:empty?)
        sha, author, subject = head.split(FIELD, 3)
        branch = subject[MERGED, 1]
        landed = branch ? " landed from #{branch}" : ""
        "#{sha} #{author}#{landed}: #{subject}\n  files: #{files.join(", ")}"
      end

      def git_dir(held) = capture(held, "rev-parse", "--path-format=absolute", "--git-common-dir").strip

      def capture(held, *args)
        result = Git.new.capture(*args, chdir: checkout(held))
        raise ConsoleCapture::Failure, "#{checkout(held)}: git #{args.first} failed" unless result.ok?

        result.out
      end

      def checkout(held) = plain(held[:checkout]) || @tune[:checkout] || Dir.pwd

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
