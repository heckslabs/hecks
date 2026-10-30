# frozen_string_literal: true

require_relative "../../../hecks"
# Load the era plugin before `Hecks.boot` (see hecks run).
require_relative "../../ports/persistence/plugins/era"
require_relative "../../fuzzing"
require_relative "../../corpus"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control target.seed`: identifies every corpus domain as a
    # rotation `Target`, printing each one's inferred capabilities. It is idempotent: references
    # already on file are skipped whatever their status (re-`Identify` refuses).
    #
    # It skips `lib/hecks/framework` (no standalone Rust binary) on purpose.
    class QaSeedTargets
      # Identifies the targets the ledger lacks.
      #
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` points at another ledger
      # @param out [IO] where each target's outcome goes
      # @return [Integer] 0 once seeded
      # @raise [SystemExit] when the ledger does not boot or a corpus path is missing
      def self.call(root:, env: ENV, out: $stdout)
        new(root: root, env: env, out: out).call
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` points at another ledger
      # @param out [IO] where each target's outcome goes
      def initialize(root:, env: ENV, out: $stdout)
        @root = root
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
        @out = out
      end

      # @return [Integer] 0 once seeded
      # @raise [SystemExit] when the ledger does not boot or a corpus path is missing
      def call
        # reference => path relative to the repository root, discovered from the corpus.
        seed = Hecks::Corpus.rotation_targets(root: @root)
        runtime = begin
          Hecks.boot(@domain_dir)
        rescue StandardError => e
          abort "the QualityControl ledger did not boot — fix the ledger itself before seeding it " \
                "(#{e.class}: #{e.message})"
        end
        existing = runtime.query("QualityControl::Target.All").map { |row| row[:reference][:value] }
        seed.each { |reference, path| identify(reference, path, existing) }
        0
      end

      private

      def identify(reference, path, existing)
        capabilities = Hecks::Fuzzing::TargetCapabilities.infer(File.join(@root, path)).join(",")
        if existing.include?(reference)
          @out.puts "already on file: #{reference} (#{path}; capabilities #{capabilities})"
          return
        end
        abort "#{reference} names a path that does not exist on disk: #{path}" unless File.directory?(File.join(@root, path))

        ::QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
        @out.puts "identified: #{reference} (#{path}; capabilities #{capabilities})"
      end
    end
  end
end
