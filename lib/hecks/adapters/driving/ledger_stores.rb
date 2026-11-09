# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

module Hecks
  module Adapters
    module Driving
      # The store rows (`store Tickets::Work`, `SqliteAt ...`, where it was declared) of the two
      # checkouts a worktree's write is judged between.
      #
      # The worktree's rows come from the registry the process already holds, so nothing is
      # booted twice. The main checkout's rows come from its own launcher (`hecks config`), because
      # only that process loads its overlay files; they are kept under the cache directory, named
      # for a fingerprint of every world and hecksagon file the rows are read from.
      module LedgerStores
        # Where a checkout keeps the Hecks domain, relative to its root.
        DOMAIN = "lib/hecks/hecks"

        # The files the rows are read from, under the domain directory and `environments/`.
        DECLARATIONS = "**/*.{hecksagon,world}"

        # A line of `hecks config` that is a store row, such as
        # `store Tickets::Work: SqliteAt /x (source)`.
        ROW = /\A(store \S+): (.*) \(([^()]*)\)\z/

        # Raised when the main checkout's stores cannot be read, so a write is refused, not lost.
        class Unreadable < StandardError; end

        # Runs a launcher in a directory and answers its standard output and success.
        LAUNCH = lambda do |launcher, args, directory|
          out, _err, status = Open3.capture3({ "BUNDLE_GEMFILE" => nil }, launcher, *args, chdir: directory)
          [out, status.success?]
        end

        module_function

        # @param runtime [#registry] the booted domain or the described one the line runs in
        # @param worktree [String] the root of the worktree the line runs in
        # @param seams [Hash] `:cache` (a directory) and `:launch` (runs a launcher), for specs
        # @return [#call] answers the store rows of a checkout root
        def for_runtime(runtime, worktree, **seams)
          lambda do |root|
            root == worktree ? registry_rows(runtime.registry) : main_rows(root, **seams)
          end
        end

        # @param registry [Hecks::Runtime::Registry]
        # @return [Array<Array(String, String, String)>] the store rows the registry resolves
        def registry_rows(registry)
          require_relative "../../hecks/adapters/settings_reading"
          Hecks::Adapters::SettingsReading.new.registry_stores(registry)
        end

        # The rows of a main checkout, from the cache when its declaration files are unchanged.
        #
        # @param root [String] the main checkout's root
        # @raise [Unreadable] when its launcher answers no store rows
        # @return [Array<Array(String, String, String)>]
        def main_rows(root, cache: Hecks::CacheDir.path("ledger_stores"), launch: LAUNCH)
          file = File.join(cache, "#{fingerprint(root)}.json")
          kept = read(file)
          return kept if kept

          rows = launched(root, launch)
          write(file, rows)
          rows
        end

        # @return [String] a digest of the paths, sizes and times of the files the rows come from
        def fingerprint(root)
          files = Dir.glob(File.join(root, DOMAIN, DECLARATIONS)) + Dir.glob(File.join(root, "environments/*.{hecksagon,world}"))
          stats = files.sort.map { |path| [path, File.size(path), File.mtime(path).to_f].join(":") }
          Digest::SHA256.hexdigest((stats + [ENV["HECKS_ENVIRONMENT"].to_s]).join("\n"))
        end

        # @return [Array<Array(String, String, String)>] the rows main's own launcher reports
        def launched(root, launch)
          args = ["config", "domain.value=#{File.join(root, DOMAIN)}"]
          out, ok = launch.call(File.join(root, "exe/hecks"), args, root)
          rows = out.to_s.lines.filter_map { |line| ROW.match(line.chomp)&.captures }
          raise Unreadable, "the main checkout (#{root}) did not report its stores" if !ok || rows.empty?

          rows
        end

        # @return [Array, nil] the rows kept in a file, or nil when there are none to trust
        def read(file)
          rows = JSON.parse(File.read(file))
          rows if rows.is_a?(Array) && rows.all? { |row| row.is_a?(Array) && row.size == 3 }
        rescue SystemCallError, JSON::ParserError
          nil
        end

        # Keeps rows beside their fingerprint. A cache that cannot be written is a miss, not an
        # error.
        def write(file, rows)
          FileUtils.mkdir_p(File.dirname(file))
          scratch = "#{file}.#{Process.pid}"
          File.write(scratch, JSON.generate(rows))
          File.rename(scratch, file)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
