# frozen_string_literal: true

require_relative "../tools"
require_relative "../corpus"

module Hecks
  module Tools
    # Prints the Rust-facing corpus from `Hecks::Corpus`, for CI steps and for asking what CI walks.
    # Takes one flag (`hecks corpus_rust_coverage <flag>`):
    #
    #   --rust-domains      feature and path of every in-repo domain with a Cargo feature
    #   --rust-regen-order  paths `hecks regenerate_corpus` regenerates, in order
    #   --rust-coverage     run the coverage tool over every generated module; a
    #                       Corpus::RUST_COVERAGE_PENDING module must still fail,
    #                       every other one must pass
    module CorpusReport
      USAGE = "usage: hecks corpus_rust_coverage --rust-domains | --rust-regen-order | --rust-coverage"

      module_function

      # Prints the report the first argument asks for.
      #
      # @param argv [Array<String>] one of the three flags
      # @param root [String] the checkout
      # @return [Integer] 0, or 1 when a coverage check does not come out as it must
      # @raise [SystemExit] with the usage line when the flag is unknown
      def main(argv, root: Tools::ROOT)
        case argv.first
        when "--rust-domains"
          Hecks::Corpus.rust_domains.each { |domain| puts "#{domain.feature}\t#{relative(domain.dir, root)}" }
          0
        when "--rust-regen-order"
          Hecks::Corpus.rust_regen_order.each { |domain| puts relative(domain.dir, root) }
          0
        when "--rust-coverage" then rust_coverage
        else abort USAGE
        end
      end

      # @param path [String] an absolute path
      # @param root [String] the checkout
      # @return [String] the path relative to `root`
      def relative(path, root) = path.delete_prefix("#{root}/")

      # Runs the coverage tool for each module in this process.
      #
      # @param modules [Array<String>] the generated modules
      # @return [Hash{String => Array}] each module's `[passed, output]`
      def coverage_results(modules)
        require_relative "../rust_build"
        modules.to_h do |name|
          result = Hecks::RustBuild.capture("rust_coverage", [name])
          [name, [result.ok?, result.out + result.err]]
        end
      end

      # @return [Integer] 0 when every module is as it must be, 1 otherwise
      # @raise [SystemExit] when `RUST_COVERAGE_PENDING` names a module that does not exist
      def rust_coverage
        modules = Hecks::Corpus.generated_modules
        pending = Hecks::Corpus::RUST_COVERAGE_PENDING
        unknown = pending.keys - modules
        if unknown.any?
          abort "hecks corpus_rust_coverage: RUST_COVERAGE_PENDING names #{unknown.join(", ")}, " \
                "which has no generated module"
        end

        results = coverage_results(modules)
        problems = modules.filter_map do |name|
          passed, output = results.fetch(name)
          if pending.key?(name)
            puts "#{name}: pending (#{passed ? "NOW PASSES" : "still fails"}) — #{pending[name]}"
            "#{name} passes now — delete it from Hecks::Corpus::RUST_COVERAGE_PENDING" if passed
          else
            puts "#{name}: #{passed ? "ok" : "FAILED"}"
            "#{name} failed:\n#{output}" unless passed
          end
        end

        return puts("hecks corpus_rust_coverage: #{modules.size} generated modules checked").then { 0 } if problems.empty?

        warn problems.join("\n\n")
        1
      end
    end
  end
end
