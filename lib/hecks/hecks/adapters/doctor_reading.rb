# frozen_string_literal: true

require "hecks"
require "open3"
require "uri"
require_relative "doctor_reading/report"

module Hecks
  module Adapters
    # The `Doctor` port's adapter for `Checkout`: one line per check of whether this copy can run
    # Hecks here, each with the fix when it is not ok. It reads and never writes: it does not boot
    # a domain (a boot can mint an era), write to a store, or call GitHub.
    class DoctorReading
      include Report

      # The channel a rust-toolchain.toml pins.
      FIRST_LINE = /\A[^\n]*/

      CHANNEL_PIN = /channel\s*=\s*"([^"]+)"/

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # @param held [Hash] `domain`, a checkout directory (the current directory when absent)
      # @return [Hash{Symbol => String}] `text:` one line per check and the overall status
      def doctor(**held)
        directory = plain(held[:domain]) || Dir.pwd
        rows = [overlays(directory), worktree(directory), toolchain(directory),
                database(directory), version(directory)]
        { text: render(rows) }
      end

      private

      # Each row is [name, status, detail, fix], where status is :ok, :warn or :fail.
      def overlays(directory)
        files = overlay_files(directory)
        bad = files.filter_map { |path| (error = syntax_error(path)) && [File.basename(path), error] }
        return row("overlay files", :ok, "#{files.size} read") if bad.empty?

        name, error = bad.first
        row("overlay files", :fail, "#{name} does not parse: #{error}", "fix the syntax in #{name}")
      end

      def overlay_files(directory)
        [directory, Dir.pwd].uniq.flat_map { |where| Dir[File.join(where, "*.local.{world,hecksagon}")] }.uniq
      end

      # The first line of a compile error, or nil when the file is valid Ruby. Compiling never runs it.
      def syntax_error(path)
        RubyVM::InstructionSequence.compile(File.read(path), path)
        nil
      rescue SyntaxError => e
        first_line(e)
      end

      def worktree(directory)
        out, status = Open3.capture2e("git", "-C", directory, "rev-parse", "--git-dir", "--git-common-dir")
        return row("worktree", :warn, "not a git checkout", "run from a hecks checkout") unless status.success?

        git_dir, common = out.lines.map(&:strip)
        return row("worktree", :ok, "main checkout") if git_dir == common

        unseen_overlays(directory, File.dirname(File.expand_path(common, directory)))
      end

      def unseen_overlays(directory, main)
        here = Dir[File.join(directory, "lib/hecks/hecks/*.local.*")]
        there = Dir[File.join(main, "lib/hecks/hecks/*.local.*")]
        return row("worktree", :ok, "linked worktree sees the main checkout's overlays") if here.any? || there.empty?

        row("worktree", :warn, "linked worktree cannot see #{there.size} overlay file(s) in #{main}",
            "run from #{main}")
      end

      def toolchain(directory)
        pin = File.read(File.join(directory, "rust-toolchain.toml"))[CHANNEL_PIN, 1]
        installed = rustc_version
        return row("toolchain", :warn, "rustc not on PATH", "install the pinned toolchain with rustup") unless installed
        return row("toolchain", :ok, installed) if pin && installed.include?(pin)

        row("toolchain", :warn, "installed #{installed}, pinned #{pin || "none"}", "rustup toolchain install #{pin}")
      rescue Errno::ENOENT
        row("toolchain", :warn, "no rust-toolchain.toml here", "run from a hecks checkout")
      end

      def rustc_version
        out, status = Open3.capture2e("rustc", "--version")
        status.success? ? out.strip : nil
      rescue Errno::ENOENT
        nil
      end

      # The default store of the domain at this directory, checked without booting it.
      def database(directory)
        registry = Hecks.describe(directory).registry
        store(registry, registry.first_domain_name)
      rescue StandardError, ScriptError => e
        row("store", :warn, "could not be read: #{first_line(e)}", "fix the overlay files first")
      end

      # The default store of one domain: Memory, a file store, or a Postgres database to reach.
      def store(registry, name)
        adapter = registry.default_adapter_for(name)
        return row("store", :ok, "Memory") if adapter.nil? || adapter.to_s == "Memory"

        url = registry.default_database_for(name)
        return reach(url) if url.to_s.start_with?("postgres")

        file_store(adapter.to_s, url)
      end

      # A file store is usable when its directory exists; the file itself is made on first write.
      def file_store(adapter, path)
        return row("store", :ok, adapter) if path.nil?

        dir = File.dirname(path.to_s)
        return row("store", :ok, "#{adapter}, #{path}") if File.directory?(dir)

        row("store", :fail, "#{adapter} directory #{dir} is missing", "mkdir -p #{dir}")
      end

      # Postgres reachable, and the role the URL names exists; a read of the catalog, nothing written.
      def reach(url)
        require "pg"
        PG.connect(url, connect_timeout: 3) { |conn| role_row(conn, URI.parse(url).user) }
      rescue LoadError
        row("store", :warn, "pg gem not loaded, so postgres was not tested", "bundle install")
      rescue PG::Error => e
        row("store", :fail, "postgres unreachable: #{first_line(e)}", "start postgres")
      end

      def role_row(conn, role)
        exists = conn.exec_params("select 1 from pg_roles where rolname = $1", [role]).ntuples.positive?
        return row("store", :ok, "postgres answers, role #{role} exists") if exists

        row("store", :fail, "postgres answers, role #{role} is missing", "create the role: createuser #{role}")
      end

      def version(directory)
        ahead, status = Open3.capture2e("git", "-C", directory, "rev-list", "--count", "origin/main..main")
        base = "hecks #{Hecks::VERSION}"
        return row("version", :ok, base) unless status.success? && ahead.to_i.positive?

        row("version", :warn, "#{base}, local main #{ahead.strip} commit(s) ahead of origin/main", "push when ready")
      end

      def row(name, status, detail, fix = nil) = [name, status, detail, fix]

      def first_line(error)
        error.message[FIRST_LINE].to_s.strip
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
