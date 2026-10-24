# frozen_string_literal: true

require "json"
require "open3"
require "hecks/projector/exporter"

module Hecks
  module Adapters
    module Rehearsal
      # The Rust host's mint audit (`reference_validate`), run over the translated rows through the
      # `validate_harness` binary, as the second engine of a rehearsal.
      #
      # The binary is found by `HECKS_VALIDATE_HARNESS`, else under `rust/host/target` of the
      # checkout this gem runs from (`cargo build --bin validate_harness`); a rehearsal never
      # builds it. Without one the engine is reported as not run.
      class RustAudit
        # @!attribute [r] ran
        #   @return [Boolean] whether the harness answered
        # @!attribute [r] violations
        #   @return [Array<String>] its refusals, `Aggregate#id: wording`
        # @!attribute [r] note
        #   @return [String] why it did not run, or what it ran over
        # @!attribute [r] rows
        #   @return [Integer] how many rows it was given (zero when it did not run)
        Result = Struct.new(:ran, :violations, :note, :rows, keyword_init: true)

        # @return [String, nil] the harness binary, when one stands
        def self.binary
          root = File.expand_path("../../../../..", __dir__)
          built = %w[debug release].map { |profile| "#{root}/rust/host/target/#{profile}/validate_harness" }
          [ENV.fetch("HECKS_VALIDATE_HARNESS", nil), *built].compact.find { |path| File.executable?(path) }
        end

        # @param subject [Subject] the loaded domain, whose IR the audit is held to
        # @param states [Hash{String => Hash{String => Hash}}] aggregate name, then id, then state
        # @return [Result] what the harness refused, or why it did not run
        def self.call(subject, states)
          path = binary
          return new(nil, subject).stood_down("no validate_harness built: cargo build --bin validate_harness") unless path

          new(path, subject).call(states)
        end

        # @param path [String, nil] the harness binary
        # @param subject [Subject] the loaded domain
        def initialize(path, subject)
          @path = path
          @subject = subject
        end

        # @param states [Hash] aggregate name, id, state
        # @return [Result] the harness's answer
        def call(states)
          cases = states.flat_map { |name, rows| rows.map { |id, state| case_for(name, id, state) } }
          out, err, status = Open3.capture3(@path, stdin_data: JSON.generate("ir" => ir, "cases" => cases))
          return stood_down("validate_harness failed: #{err.lines.first&.strip}") unless status.success?

          answered(out, cases.size)
        end

        # @param note [String] why the engine did not run
        # @return [Result] an answer that refused nothing
        def stood_down(note) = Result.new(ran: false, violations: [], note: note, rows: 0)

        private

        def answered(out, rows)
          Result.new(ran: true, violations: refusals(out), note: "ran over #{rows} rows", rows: rows)
        end

        def ir = Projector::Exporter.call(@subject.registry).fetch(@subject.bluebook_name)

        def case_for(name, id, state)
          { "aggregate" => name, "id" => id, "state" => JSON.parse(JSON.generate(state)) }
        end

        def refusals(out)
          JSON.parse(out).fetch("results").flat_map { |result| result["violations"] || [result["error"]].compact }
        end
      end
    end
  end
end
