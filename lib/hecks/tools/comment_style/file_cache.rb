# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "../../tools"
require_relative "file_facts"
require_relative "linter_digest"

module Hecks
  module Tools
    module CommentStyle
      # The facts of each Ruby file the linter has parsed, kept outside the checkout by the sha of
      # the file's text, so a run parses only the files whose text it has not seen. The cache is
      # one JSON file per {LinterDigest}: a change to the linter starts an empty one, and the
      # others are removed when it is written.
      class FileCache
        # Where the cache is kept, unless `HECKS_COMMENT_CACHE` names another directory.
        DEFAULT_DIR = File.join(Dir.home, ".cache", "hecks", "comment_style")

        # The value of `HECKS_COMMENT_CACHE` that keeps no cache.
        OFF = "off"

        # Days an entry no run has read is kept.
        KEPT_DAYS = 14

        # The cache that keeps nothing: every file is parsed, and nothing is written.
        module None
          module_function

          # @param path [String] a Ruby file
          # @return [FileFacts] its facts, parsed now
          def facts(path) = FileFacts.of(SourceFile.new(path))

          # Writes nothing.
          #
          # @return [void]
          def save!; end
        end

        # The switch the spec runner sets: a spec keeps no cache unless it names a directory.
        SPEC_SWITCH = "HECKS_WRITES_LOCAL"

        # @param env [Hash{String => String}] the environment, read for `HECKS_COMMENT_CACHE`
        # @return [FileCache, None] the cache a command line run uses
        def self.default(env = ENV)
          dir = env.fetch("HECKS_COMMENT_CACHE") { env[SPEC_SWITCH] ? OFF : DEFAULT_DIR }
          dir == OFF ? None : new(dir)
        end

        attr_reader :file

        # @param dir [String] the directory the cache lives in
        # @param digest [String] the linter's digest, which names the cache file
        def initialize(dir, digest: LinterDigest.current)
          @dir = dir
          @file = File.join(dir, "#{digest}.json")
          @entries = read
          @seen = {}
        end

        # @param path [String] a Ruby file
        # @return [FileFacts] its facts, from the cache when its text was seen before
        def facts(path)
          source = File.read(path)
          sha = Digest::SHA256.hexdigest(source)
          held = @entries[sha]
          facts = held ? FileFacts.from_h(held["facts"]) : FileFacts.of(SourceFile.new(path, source))
          @seen[sha] = { "facts" => facts.to_h, "day" => today }
          facts
        end

        # Writes what this run read over what is on disk, dropping entries unread for `KEPT_DAYS`
        # and caches of another linter. The write is a rename, so a reader never sees half a file.
        #
        # @return [void]
        def save!
          FileUtils.mkdir_p(@dir)
          temporary = "#{@file}.#{Process.pid}.tmp"
          File.write(temporary, JSON.generate(kept))
          File.rename(temporary, @file)
          (Dir[File.join(@dir, "*.json")] - [@file]).each { |stale| FileUtils.rm_f(stale) }
        end

        private

        def kept
          read.merge(@seen).select { |_, entry| entry["day"].to_i > today - KEPT_DAYS }
        end

        def read
          File.exist?(@file) ? JSON.parse(File.read(@file)) : {}
        rescue JSON::ParserError
          {}
        end

        def today = Time.now.to_i / 86_400
      end
    end
  end
end
