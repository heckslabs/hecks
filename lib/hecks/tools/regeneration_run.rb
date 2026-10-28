# frozen_string_literal: true

require "fileutils"
require_relative "../tools"
require_relative "../corpus"
require_relative "regeneration_run/scratch"

module Hecks
  module Tools
    # Regenerates every corpus domain's Rust output with `hecks project_rust`, or checks that the
    # output on disk is what that would write. Only pizzas, `mod.rs` and `Cargo.toml` are committed.
    #
    # The domain list comes from `Hecks::Corpus.rust_regen_order`, never a hand-kept list, and is
    # handed to every run as the declared domains: a domain's files, `generated/mod.rs` and
    # Cargo's features come out the same in whatever order the domains run. The order is fixed
    # anyway (sorted by relative path). If the domain set changes, re-run and commit what changed.
    #
    #   hecks regenerate_corpus         # discover, regenerate, print the plan
    #   hecks regenerate_corpus --check # a scratch crate, never the tree; fail on any difference
    #   hecks regenerate_corpus domains=a,b # only those; `mod.rs` and Cargo's features stay put
    module RegenerationRun
      # The refusal when no domain is found.
      NO_DOMAINS = "hecks regenerate_corpus: discovered ZERO domains with committed rust/src/generated/ " \
                   "output in Hecks::Corpus — that almost certainly means this script is running from the " \
                   "wrong directory, or something upstream deleted rust/src/generated/ entirely. Refusing " \
                   "to silently treat that as \"nothing to regenerate.\""

      # The argument naming the domains to regenerate, comma-separated, as the launcher passes it.
      DOMAINS_ARG = "domains="

      # The scratch crate of a check: `scratch_crate`, `verdict` and `matches_scratch?`.
      extend Scratch

      module_function

      # Regenerates the corpus, or checks it.
      #
      # @param argv [Array<String>] `--check` to project into a scratch crate and compare, and
      #   `domains=a,b` to run only those domains
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when a check finds a difference
      # @raise [SystemExit] when no corpus domain is found, a named domain is not one, or a domain
      #   fails to regenerate
      def main(argv, root: Tools::ROOT)
        Dir.chdir(root) do
          names = named(argv)
          domains = plan(root, names)
          # A check projects into a scratch copy of the crate; the forked children inherit the
          # workspace with the process.
          scratch = argv.include?("--check") && scratch_crate(root)
          run_plan(domains, scratch, partial: !names.nil?)
        end
      end

      # Regenerates the domains, then judges the scratch crate when there is one.
      #
      # @param domains [Array<String>] the domains, in run order
      # @param scratch [String, false] the scratch crate of a check, removed here
      # @param partial [Boolean] whether these are some of the corpus's domains, not all
      # @return [Integer] 0, or 1 when a check finds a difference
      def run_plan(domains, scratch, partial: false)
        with_rust_dir(scratch) { regenerate(domains, partial: partial) }
        scratch ? verdict(scratch) : 0
      ensure
        FileUtils.rm_rf(scratch) if scratch
      end

      # Builds in `scratch` while the block runs; with none, in the workspace already chosen.
      def with_rust_dir(scratch, &)
        require "hecks/rust_build"
        return yield unless scratch

        Hecks::RustBuild.in_workspace(scratch, &)
      end

      # @param argv [Array<String>] the arguments of the run
      # @return [Array<String>, nil] the feature names `domains=` lists, nil when it is not given
      def named(argv)
        list = argv.find { |arg| arg.start_with?(DOMAINS_ARG) }
        list&.delete_prefix(DOMAINS_ARG)&.split(",")
      end

      # `meta` is never in the list: `Hecks::Corpus::RUST_ELSEWHERE` routes it to the check that
      # owns it instead.
      #
      # @param root [String] the checkout
      # @param names [Array<String>, nil] the features to regenerate; nil for every domain
      # @return [Array<String>] the domains to regenerate, relative to `root`, in run order
      # @raise [SystemExit] when there are none, or a name is not a domain: the message lists the
      #   valid ones
      def plan(root, names = nil)
        chosen = Hecks::Corpus.rust_domains_named(names, root: root)
        domains = chosen.map { |domain| domain.dir.delete_prefix("#{root}/") }

        abort NO_DOMAINS if domains.empty?

        puts "hecks regenerate_corpus: regenerating #{domains.size} domain(s), in this fixed order:"
        domains.each { |d| puts "  #{d}" }
        puts
        domains
      rescue Hecks::Corpus::UnknownDomain => e
        abort "hecks regenerate_corpus: #{e.message}"
      end

      # Builds the memoized grammar registry once and forks for each domain, one at a time and in
      # order. Every run is told the declared domains, so `mod.rs` and Cargo's features come from
      # that list and Cargo's `default` stays put: the order does not change what any run writes. A
      # partial run (some of the domains) leaves `mod.rs` and Cargo's features alone.
      #
      # @param domains [Array<String>] the domains, in run order
      # @param partial [Boolean] whether these are some of the corpus's domains, not all
      # @return [void]
      def regenerate(domains, partial: false)
        require "hecks"
        require "hecks/bluebook/meta_validator"
        require "hecks/rust_build"
        require "hecks/rust_build/project_rust"
        Hecks::Bluebook::MetaValidator.grammar_registry
        flags = declared_flags(partial: partial)
        domains.each { |domain| project_rust_in_fork(domain, flags) }
      end

      # The corpus's declared domains as `hecks project_rust` flags: the domains of the regeneration
      # order, and the features the corpus routes elsewhere (`meta`, which every run generates).
      # Cargo's `default` stays on the feature the tracked `rust/Cargo.toml` names, or on the last
      # declared domain when it names none.
      #
      # @param partial [Boolean] whether the run is of some domains: it is told so
      # @return [Array<String>] the flags
      def declared_flags(partial: false)
        require "hecks/rust_build/project_rust"
        features = Hecks::Corpus.rust_regen_order.map(&:feature)
        default = Hecks::Corpus.cargo_default || features.last
        declared = Hecks::RustBuild::ProjectRust::Declared
        declared.new(features + Hecks::Corpus::RUST_ELSEWHERE.keys, default, partial: partial).flags
      end

      # Forks so the child inherits the memoized grammar registry instead of rebuilding it. The
      # child's output goes through a pipe and is printed here, so it reaches whoever captures this
      # process's stdout.
      #
      # @param domain [String] the domain, relative to the checkout
      # @param flags [Array<String>] the declared-domain flags
      # @return [void]
      # @raise [SystemExit] when the child fails
      def project_rust_in_fork(domain, flags)
        puts "== hecks project_rust #{domain} =="
        reader, writer = IO.pipe
        pid = fork { run_child(reader, writer, [domain, *flags]) }
        writer.close
        $stdout.write(reader.read)
        reader.close
        _, status = Process.wait2(pid)
        abort "hecks regenerate_corpus: hecks project_rust #{domain} failed (#{status.inspect})" unless status.success?
        puts
      end

      # @param reader [IO] the parent's end of the pipe, closed here
      # @param writer [IO] the child's end, which becomes its stdout and stderr
      # @param argv [Array<String>] the arguments of `hecks project_rust`
      # @return [void] never returns: the child leaves without the parent's exit handlers
      def run_child(reader, writer, argv)
        reader.close
        # The real descriptors, not the globals: a caller may have swapped those for a buffer.
        STDOUT.reopen(writer) # rubocop:disable Style/GlobalStdStream
        STDERR.reopen(writer) # rubocop:disable Style/GlobalStdStream
        $stdout = STDOUT
        $stderr = STDERR
        status = child_status(argv)
        $stdout.flush
        exit!(status)
      end

      # @return [Integer] the exit status of `hecks project_rust` with the arguments
      def child_status(argv)
        Hecks::RustBuild.run("project_rust", argv, out: STDOUT, err: STDERR) # rubocop:disable Style/GlobalStdStream
      rescue SystemExit => e
        e.status
      rescue StandardError => e
        warn "#{e.class}: #{e.message}"
        1
      end
    end
  end
end
