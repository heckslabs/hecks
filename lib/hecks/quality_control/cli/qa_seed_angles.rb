# frozen_string_literal: true

require_relative "../../../hecks"
# The era/lineage plugin has to be loaded before `Hecks.boot` for a real (non-Memory) adapter
# (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "qa_seed_angles/seed"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control angle.seed`: seeds the QualityControl ledger's
    # `Angle` backlog with the practice's starting leads. It is idempotent: only references not
    # already on file are proposed.
    class QaSeedAngles
      # Proposes the leads the ledger lacks.
      #
      # @param root [String] the repository root, where `qa/bluebook` is the ledger
      # @param out [IO] where each lead's outcome goes
      # @return [Integer] 0 once seeded
      # @raise [SystemExit] when the ledger does not boot
      def self.call(root:, out: $stdout)
        new(root: root, out: out).call
      end

      # @param root [String] the repository root
      # @param out [IO] where each lead's outcome goes
      def initialize(root:, out: $stdout)
        @domain_dir = File.join(root, "qa/bluebook")
        @out = out
      end

      # @return [Integer] 0 once seeded
      # @raise [SystemExit] when the ledger does not boot
      def call
        runtime = boot_ledger
        existing = runtime.query("QualityControl::Angle.All").map { |row| row[:reference][:value] }
        SEED.each do |angle|
          if existing.include?(angle[:reference])
            @out.puts "already on file: #{angle[:reference]}"
          else
            propose(angle)
          end
        end
        0
      end

      private

      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot — fix the ledger itself before seeding it " \
              "(#{e.class}: #{e.message})"
      end

      def propose(angle)
        record = ::QualityControl::Angle.propose!(
          reference: { value: angle[:reference] }, premise: { value: angle[:premise] },
          citation: { value: angle[:citation] }, proposer: { value: angle[:proposer] },
          now: { value: Time.now.to_i }
        )
        return @out.puts "proposed: #{angle[:reference]}" unless angle[:resolution]

        record.investigate!.build!(resolution: { value: angle[:resolution] })
        @out.puts "proposed, investigated, and built: #{angle[:reference]}"
      end
    end
  end
end
