# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../tools"
require_relative "../corpus"

module Hecks
  module Tools
    # Regenerates every corpus domain's committed Rust output with `hecks project_rust`, or checks
    # that the committed output is what a regeneration would write.
    #
    # The domain list comes from `Hecks::Corpus.rust_regen_order`, never a hand-kept list. The
    # order is fixed (sorted by relative path): domains that share governance/, identity/,
    # Cargo.toml and generated/mod.rs stamp them with whichever ran last, so it must not flap. If
    # the domain set or the sort rule changes, re-run and commit the output; never hand-edit stamps.
    #
    #   hecks regenerate_corpus         # discover, regenerate, print the plan
    #   hecks regenerate_corpus --check # regenerate into a scratch crate; fail on any difference
    #
    # `--check` never writes the working tree: it runs beside the parallel suite.
    module RegenerationRun
      # The refusal when no domain is found.
      NO_DOMAINS = "hecks regenerate_corpus: discovered ZERO domains with committed rust/src/generated/ " \
                   "output in Hecks::Corpus — that almost certainly means this script is running from the " \
                   "wrong directory, or something upstream deleted rust/src/generated/ entirely. Refusing " \
                   "to silently treat that as \"nothing to regenerate.\""

      module_function

      # Regenerates the corpus, or checks it.
      #
      # @param argv [Array<String>] `--check` to project into a scratch crate and compare
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when a check finds a difference
      # @raise [SystemExit] when no corpus domain is found or a domain fails to regenerate
      def main(argv, root: Tools::ROOT)
        Dir.chdir(root) do
          domains = plan(root)
          # A check projects into a scratch copy of the crate; the forked children inherit
          # HECKS_RUST_DIR.
          scratch = argv.include?("--check") && scratch_crate(root)
          run_plan(domains, scratch)
        end
      end

      # Regenerates the domains, then judges the scratch crate when there is one.
      #
      # @param domains [Array<String>] the domains, in run order
      # @param scratch [String, false] the scratch crate of a check, removed here
      # @return [Integer] 0, or 1 when a check finds a difference
      def run_plan(domains, scratch)
        with_rust_dir(scratch) { regenerate(domains) }
        scratch ? verdict(scratch) : 0
      ensure
        FileUtils.rm_rf(scratch) if scratch
      end

      # Points `HECKS_RUST_DIR` at `scratch` while the block runs, then puts it back.
      def with_rust_dir(scratch)
        saved = ENV.fetch("HECKS_RUST_DIR", nil)
        ENV["HECKS_RUST_DIR"] = scratch if scratch
        yield
      ensure
        saved ? ENV["HECKS_RUST_DIR"] = saved : ENV.delete("HECKS_RUST_DIR")
      end

      # `meta` is never in the list: `Hecks::Corpus::RUST_ELSEWHERE` routes it to the check that
      # owns it instead.
      #
      # @param root [String] the checkout
      # @return [Array<String>] the domains to regenerate, relative to `root`, in run order
      # @raise [SystemExit] when there are none
      def plan(root)
        domains = Hecks::Corpus.rust_regen_order.map { |domain| domain.dir.delete_prefix("#{root}/") }

        abort NO_DOMAINS if domains.empty?

        puts "hecks regenerate_corpus: regenerating #{domains.size} domain(s), in this fixed order:"
        domains.each { |d| puts "  #{d}" }
        puts
        domains
      end

      # Builds the memoized grammar registry once and forks for each domain, one at a time and in
      # order, because the shared outputs depend on which domain ran last.
      #
      # @param domains [Array<String>] the domains, in run order
      # @return [void]
      def regenerate(domains)
        require "hecks"
        require "hecks/bluebook/meta_validator"
        require "hecks/rust_build"
        Hecks::Bluebook::MetaValidator.grammar_registry
        domains.each { |domain| project_rust_in_fork(domain) }
      end

      # Forks so the child inherits the memoized grammar registry instead of rebuilding it. The
      # child's output goes through a pipe and is printed here, so it reaches whoever captures this
      # process's stdout.
      #
      # @param domain [String] the domain, relative to the checkout
      # @return [void]
      # @raise [SystemExit] when the child fails
      def project_rust_in_fork(domain)
        puts "== hecks project_rust #{domain} =="
        reader, writer = IO.pipe
        pid = fork { run_child(reader, writer, domain) }
        writer.close
        $stdout.write(reader.read)
        reader.close
        _, status = Process.wait2(pid)
        abort "hecks regenerate_corpus: hecks project_rust #{domain} failed (#{status.inspect})" unless status.success?
        puts
      end

      # @param reader [IO] the parent's end of the pipe, closed here
      # @param writer [IO] the child's end, which becomes its stdout and stderr
      # @param domain [String] the domain
      # @return [void] never returns: the child leaves without the parent's exit handlers
      def run_child(reader, writer, domain)
        reader.close
        # The real descriptors, not the globals: a caller may have swapped those for a buffer.
        STDOUT.reopen(writer) # rubocop:disable Style/GlobalStdStream
        STDERR.reopen(writer) # rubocop:disable Style/GlobalStdStream
        $stdout = STDOUT
        $stderr = STDERR
        status = child_status(domain)
        $stdout.flush
        exit!(status)
      end

      # @return [Integer] the exit status of `hecks project_rust` for the domain
      def child_status(domain)
        Hecks::RustBuild.run("project_rust", [domain], out: STDOUT, err: STDERR) # rubocop:disable Style/GlobalStdStream
      rescue SystemExit => e
        e.status
      rescue StandardError => e
        warn "#{e.class}: #{e.message}"
        1
      end

      # A scratch crate: copies of the generated tree and Cargo.toml, all `hecks project_rust`
      # writes.
      #
      # @param root [String] the checkout
      # @return [String] the scratch directory
      def scratch_crate(root)
        scratch = Dir.mktmpdir("regen-codegen-check")
        FileUtils.mkdir_p(File.join(scratch, "src"))
        FileUtils.cp_r(File.join(root, "rust/src/generated"), File.join(scratch, "src/generated"))
        FileUtils.cp(File.join(root, "rust/Cargo.toml"), scratch)
        scratch
      end

      # The gate: the scratch projection must match the generated sources and Cargo.toml on disk.
      #
      # @param scratch [String] the scratch crate, removed here
      # @return [Integer] 0 when it matches, 1 after printing the difference
      def verdict(scratch)
        same = matches_scratch?(scratch)
        FileUtils.rm_rf(scratch)
        same ? 0 : 1
      end

      # @param scratch [String] the scratch crate
      # @return [Boolean] whether it matches the tree, printing `git diff` output when it does not
      def matches_scratch?(scratch)
        pairs = [["rust/src/generated", File.join(scratch, "src/generated")],
                 ["rust/Cargo.toml", File.join(scratch, "Cargo.toml")]]
        pairs.map do |on_disk, projected|
          out, status = Open3.capture2e("git", "diff", "--no-index", "--exit-code", "--", on_disk, projected)
          print out
          status.success?
        end.all?
      end
    end
  end
end
