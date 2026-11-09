# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "cache_dir"

module Hecks
  # What each role's MCP server may dispatch, kept on disk so a server can learn its restriction at
  # startup without loading the framework.
  #
  # A session's server learns its role from `CLAUDE_CODE_AGENT`, an environment variable Claude
  # Code gives every server it starts, on a resumed session as on a new one. The commands a role's
  # routing rows name are known only to the framework (they are patterns such as `Dispatch.*`
  # matched against the commands of the served domain), so they are worked out once per checkout
  # state, written here, and read by every server after. The file is named for a digest of what
  # decides the answer: the checkout's bluebooks under `lib/hecks/hecks` and `lib/hecks/agents`
  # and its version file, so an edit to a routing row or to a command misses.
  #
  # This file requires nothing of the framework, so the stdio server can load it first.
  module RoleServerCache
    # The directory under the cache root the files live in.
    DIRECTORY = "role-servers"

    # The domain a role's server serves, relative to the checkout.
    DOMAIN = "lib/hecks/hecks"

    # The agents bluebook, whose routing rows decide which roles are restricted.
    AGENTS_BLUEBOOK = "lib/hecks/agents/agents.bluebook"

    # What the digest covers, relative to the checkout.
    SOURCES = %w[lib/hecks/hecks lib/hecks/agents].freeze

    # Changes when the file's shape does, so older files are not read.
    FORMAT = 1

    # How many files are kept; the newest stay.
    KEEP = 16

    # What {.lookup} answers when no file holds this checkout state yet.
    MISS = :miss

    # What {.lookup} answers for a role with no routing rows, or a checkout with no agents.
    UNRESTRICTED = :unrestricted

    module_function

    # @param checkout [String] the checkout whose bluebooks decide the answer
    # @param role [String] the role the session runs as
    # @return [Array<String>, Symbol] the command names the role's rows name (empty when none names
    #   a command of the checkout, which is not permission), `UNRESTRICTED` for a role with no rows
    #   or a checkout with no agents bluebook, or `MISS` when this state has not been worked out
    def lookup(checkout, role)
      return UNRESTRICTED unless File.file?(File.join(checkout, AGENTS_BLUEBOOK))

      roles = read(checkout)
      return MISS unless roles

      roles.key?(role) ? roles.fetch(role) : UNRESTRICTED
    end

    # @param checkout [String] the checkout
    # @return [Hash{String => Array<String>}, nil] role => command names for each role with rows, or
    #   nil when there is no trusted file for this state
    def read(checkout)
      file = path(checkout)
      return nil unless file && trusted?(file)

      table_of(JSON.parse(File.read(file)))
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # @param parsed [Object] the file's JSON
    # @return [Hash{String => Array<String>}, nil] its roles, or nil when it is not a table of this
    #   format
    def table_of(parsed)
      return nil unless parsed.is_a?(Hash) && parsed["format"] == FORMAT

      roles = parsed["roles"]
      roles if roles.is_a?(Hash) && roles.values.all?(Array)
    end

    # Writes the table for this state, by rename, readable by its owner only. Best effort: a cache
    # that cannot be written is a miss next time, not an error.
    #
    # @param checkout [String] the checkout
    # @param roles [Hash{String => Array<String>}] role => command names, for every role with rows
    # @return [String, nil] the file written, or nil when it could not be
    def write(checkout, roles)
      file = path(checkout)
      return nil unless file

      FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
      scratch = "#{file}.#{Process.pid}"
      File.write(scratch, JSON.generate("format" => FORMAT, "roles" => roles), perm: 0o600)
      File.rename(scratch, file)
      prune(File.dirname(file))
      file
    rescue SystemCallError
      nil
    end

    # @param checkout [String] the checkout
    # @return [String, nil] the file for this state, or nil when the checkout has no agents bluebook
    def path(checkout)
      digest = key(checkout)
      digest && File.join(CacheDir.path(DIRECTORY), "#{digest}.json")
    end

    # @return [String, nil] a digest of the checkout's bluebooks and version file
    def key(checkout)
      return nil unless File.file?(File.join(checkout, AGENTS_BLUEBOOK))

      state = Digest::SHA256.new << "#{FORMAT}\0"
      sources(checkout).each { |file| state << file.delete_prefix(checkout) << "\0" << File.binread(file) << "\0" }
      state.hexdigest[0, 40]
    end

    # @return [Array<String>] the files the digest covers, sorted
    def sources(checkout)
      files = SOURCES.flat_map { |dir| Dir.glob(File.join(checkout, dir, "**", "*.bluebook")) }
      files << File.join(checkout, "lib/hecks/version.rb")
      files.select { |file| File.file?(file) }.sort
    end

    # A file counts only when this user owns it and nobody else can write it, since its contents
    # decide what a server dispatches.
    def trusted?(file)
      stat = File.stat(file)
      stat.owned? && stat.mode.nobits?(0o022) && File.stat(File.dirname(file)).owned?
    rescue SystemCallError
      false
    end

    # Removes all but the newest `KEEP` files.
    def prune(directory)
      files = Dir.glob(File.join(directory, "*.json")).sort_by { |file| -File.mtime(file).to_f }
      files.drop(KEEP).each { |file| File.delete(file) }
    rescue SystemCallError
      nil
    end
  end
end
