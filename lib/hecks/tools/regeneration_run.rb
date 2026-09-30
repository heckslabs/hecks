# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../tools"
require_relative "../corpus"

module Hecks
  module Tools
    # Regenerates every corpus domain's committed Rust output with `bin/project_rust`, or checks
    # that the committed output is what a regeneration would write.
    #
    # The domain list comes from `Hecks::Corpus.rust_regen_order`, never a hand-kept list. The
    # order is fixed (sorted by relative path): domains that share governance/, identity/,
    # Cargo.toml and generated/mod.rs stamp them with whichever ran last, so it must not flap. If
    # the domain set or the sort rule changes, re-run and commit the output; never hand-edit stamps.
    #
    #   bin/regen_codegen_domains         # discover, regenerate, print the plan
    #   bin/regen_codegen_domains --check # regenerate into a scratch crate; fail on any difference
    #
    # `--check` never writes the working tree: it runs beside the parallel suite.
    module RegenerationRun
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
          saved = ENV.fetch("HECKS_RUST_DIR", nil)
          ENV["HECKS_RUST_DIR"] = scratch if scratch
          begin
            begin
              regenerate(domains, root)
            ensure
              saved ? ENV["HECKS_RUST_DIR"] = saved : ENV.delete("HECKS_RUST_DIR")
            end
            scratch ? verdict(scratch) : 0
          ensure
            FileUtils.rm_rf(scratch) if scratch
          end
        end
      end

      # `meta` is never in the list: `Hecks::Corpus::RUST_ELSEWHERE` routes it to the check that
      # owns it instead.
      #
      # @param root [String] the checkout
      # @return [Array<String>] the domains to regenerate, relative to `root`, in run order
      # @raise [SystemExit] when there are none
      def plan(root)
        domains = Hecks::Corpus.rust_regen_order.map { |domain| domain.dir.delete_prefix("#{root}/") }

        if domains.empty?
          abort "bin/regen_codegen_domains: discovered ZERO domains with committed rust/src/generated/ " \
                "output in Hecks::Corpus — that almost certainly means this script is running from the " \
                "wrong directory, or something upstream deleted rust/src/generated/ entirely. Refusing " \
                "to silently treat that as \"nothing to regenerate.\""
        end

        puts "bin/regen_codegen_domains: regenerating #{domains.size} domain(s), in this fixed order:"
        domains.each { |d| puts "  #{d}" }
        puts
        domains
      end

      # Builds the memoized grammar registry once and forks for each domain, one at a time and in
      # order, because the shared outputs depend on which domain ran last.
      #
      # @param domains [Array<String>] the domains, in run order
      # @param root [String] the checkout
      # @return [void]
      def regenerate(domains, root)
        require "hecks"
        require "hecks/bluebook/meta_validator"
        Hecks::Bluebook::MetaValidator.grammar_registry
        domains.each { |domain| project_rust_in_fork(File.join(root, "bin/project_rust"), domain) }
      end

      # Forks so the child inherits the memoized grammar registry instead of rebuilding it. The
      # child's output goes through a pipe and is printed here, so it reaches whoever captures this
      # process's stdout.
      #
      # @param project_rust [String] the script that projects one domain
      # @param domain [String] the domain, relative to the checkout
      # @return [void]
      # @raise [SystemExit] when the child fails
      def project_rust_in_fork(project_rust, domain)
        puts "== bin/project_rust #{domain} =="
        reader, writer = IO.pipe
        pid = fork { run_child(reader, writer, project_rust, domain) }
        writer.close
        $stdout.write(reader.read)
        reader.close
        _, status = Process.wait2(pid)
        abort "bin/regen_codegen_domains: bin/project_rust #{domain} failed (#{status.inspect})" unless status.success?
        puts
      end

      # @param reader [IO] the parent's end of the pipe, closed here
      # @param writer [IO] the child's end, which becomes its stdout and stderr
      # @param project_rust [String] the script that projects one domain
      # @param domain [String] the domain
      # @return [void] never returns: the child leaves without the parent's exit handlers
      def run_child(reader, writer, project_rust, domain)
        reader.close
        # The real descriptors, not the globals: a caller may have swapped those for a buffer.
        STDOUT.reopen(writer) # rubocop:disable Style/GlobalStdStream
        STDERR.reopen(writer) # rubocop:disable Style/GlobalStdStream
        $stdout = STDOUT
        $stderr = STDERR
        status = begin
          ARGV.replace([domain])
          $PROGRAM_NAME = project_rust
          load project_rust
          0
        rescue SystemExit => e
          e.status
        rescue StandardError => e
          warn "#{e.class}: #{e.message}"
          1
        end
        $stdout.flush
        exit!(status)
      end

      # A scratch crate: copies of the generated tree and Cargo.toml, all `bin/project_rust` writes.
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
