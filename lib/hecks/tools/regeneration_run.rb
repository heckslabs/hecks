# frozen_string_literal: true

require "etc"
require "fileutils"
require_relative "../tools"
require_relative "../corpus"
require_relative "regeneration_run/scratch"
require_relative "regeneration_run/pool"

module Hecks
  module Tools
    # Regenerates every corpus domain's Rust output with `hecks project_rust`, or checks that the
    # output on disk is what that would write. Only pizzas, `mod.rs` and `Cargo.toml` are committed.
    #
    # The domain list comes from `Hecks::Corpus.rust_regen_order`, never a hand-kept list, and is
    # handed to every run as the declared domains: a domain's files, `generated/mod.rs` and
    # Cargo's features come out the same in whatever order the domains run. The domains run side
    # by side, one child per core unless `workers=` says otherwise (see `Pool`).
    #
    #   hecks regenerate_corpus         # discover, regenerate, print the plan
    #   hecks regenerate_corpus --check # a scratch crate, never the tree; fail on any difference
    #   hecks regenerate_corpus domains=a,b # only those; `mod.rs` and Cargo's features stay put
    #   hecks regenerate_corpus workers=1   # one domain at a time
    module RegenerationRun
      # The refusal when no domain is found.
      NO_DOMAINS = "hecks regenerate_corpus: discovered ZERO domains with committed rust/src/generated/ " \
                   "output in Hecks::Corpus — that almost certainly means this script is running from the " \
                   "wrong directory, or something upstream deleted rust/src/generated/ entirely. Refusing " \
                   "to silently treat that as \"nothing to regenerate.\""

      # The argument naming the domains to regenerate, comma-separated, as the launcher passes it.
      DOMAINS_ARG = "domains="

      # The argument saying how many domains are generated at once, as the launcher passes it.
      WORKERS_ARG = "workers="

      # What a count of workers looks like: a whole number above zero.
      POSITIVE_WHOLE_NUMBER = /\A[1-9][0-9]*\z/

      # The scratch crate of a check: `scratch_crate`, `verdict` and `matches_scratch?`.
      extend Scratch

      module_function

      # Regenerates the corpus, or checks it.
      #
      # @param argv [Array<String>] `--check` to project into a scratch crate and compare, and
      #   `domains=a,b` to run only those domains, `workers=n` to generate n at once
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when a check finds a difference
      # @raise [SystemExit] when no corpus domain is found, a named domain is not one, the workers
      #   are not a positive number, or a domain fails to regenerate
      def main(argv, root: Tools::ROOT)
        Dir.chdir(root) do
          names = named(argv)
          workers = workers_in(argv)
          domains = plan(root, names)
          # A check projects into a scratch copy of the crate; the forked children inherit the
          # workspace with the process.
          scratch = argv.include?("--check") && scratch_crate(root)
          run_plan(domains, scratch, partial: !names.nil?, workers: workers)
        end
      end

      # Regenerates the domains, then judges the scratch crate when there is one.
      #
      # @param domains [Array<String>] the domains, in run order
      # @param scratch [String, false] the scratch crate of a check, removed here
      # @param partial [Boolean] whether these are some of the corpus's domains, not all
      # @param workers [Integer] how many domains are generated at once
      # @return [Integer] 0, or 1 when a check finds a difference
      def run_plan(domains, scratch, partial: false, workers: default_workers)
        with_rust_dir(scratch) { regenerate(domains, partial: partial, workers: workers) }
        scratch ? verdict(scratch) : 0
      ensure
        FileUtils.rm_rf(scratch) if scratch
      end

      # @param argv [Array<String>] the arguments of the run
      # @return [Integer] what `workers=` gives, one child per core when it is not given
      # @raise [SystemExit] when it is not a positive whole number
      def workers_in(argv)
        given = argv.find { |arg| arg.start_with?(WORKERS_ARG) }&.delete_prefix(WORKERS_ARG)
        return default_workers unless given
        return Integer(given) if given.match?(POSITIVE_WHOLE_NUMBER)

        abort "hecks regenerate_corpus: workers=#{given} is not a positive whole number"
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

      # Builds the memoized grammar registry once, then forks `hecks project_rust` for each domain,
      # `workers` at a time (see `Pool`). Every child is told the declared domains and that it is
      # partial, so none of them writes `mod.rs` or Cargo's features: a whole run writes them once
      # here, after the last domain, from the declared list, so they come out the same however the
      # children interleave. A run of some of the domains leaves them alone.
      #
      # @param domains [Array<String>] the domains, in run order
      # @param partial [Boolean] whether these are some of the corpus's domains, not all
      # @param workers [Integer] how many domains are generated at once
      # @return [void]
      # @raise [SystemExit] when a domain fails
      def regenerate(domains, partial: false, workers: default_workers)
        require "hecks"
        require "hecks/bluebook/meta_validator"
        require "hecks/rust_build"
        require "hecks/rust_build/project_rust"
        Hecks::Bluebook::MetaValidator.grammar_registry
        Pool.new(domains, declared(partial: true).flags, workers).call
        write_manifest unless partial
      end

      # @return [Integer] how many domains a run generates at once unless told: one per core
      def default_workers = Etc.nprocessors

      # `mod.rs` and Cargo's features for the whole corpus, written once in the workspace.
      #
      # @return [void]
      def write_manifest
        declared = declared(partial: false)
        Hecks::RustBuild::ProjectRust::Manifest.new(Hecks::RustBuild.rust_dir, declared, declared.default).call
      end

      # The corpus's declared domains as `hecks project_rust` flags: the domains of the regeneration
      # order, and the features the corpus routes elsewhere (`meta`, which every run generates).
      # Cargo's `default` stays on the feature the tracked `rust/Cargo.toml` names, or on the last
      # declared domain when it names none.
      #
      # @param partial [Boolean] whether the run is of some domains: it is told so
      # @return [Array<String>] the flags
      def declared_flags(partial: false) = declared(partial: partial).flags

      # @param partial [Boolean] whether the run is of some domains
      # @return [Hecks::RustBuild::ProjectRust::Declared] the corpus's declared domains
      def declared(partial: false)
        require "hecks/rust_build/project_rust"
        features = Hecks::Corpus.rust_regen_order.map(&:feature)
        default = Hecks::Corpus.cargo_default || features.last
        Hecks::RustBuild::ProjectRust::Declared.new(features + Hecks::Corpus::RUST_ELSEWHERE.keys, default, partial: partial)
      end
    end
  end
end
