# frozen_string_literal: true

require_relative "edge_guards"
require_relative "watermark_guards"
require_relative "command_line"
require_relative "store"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The guards that need the store, in the order the mint runs them: the era resolution
          # (`RevisionResolution`, the one answer a boot and a rehearsal read), the held-shape
          # refusal,
          # then the edge guards, then the watermark.
          class Inspection
            LATER = %w[edge coverage audit].freeze

            # @param report [Report] where each guard is recorded
            # @param held [HeldDomain] the loaded domain
            # @param options [Hash] `rehearsal_ref`, `rehearsal_watermark`, `rehearsal_verdict`
            def initialize(report, held, options)
              @report = report
              @held = held
              @options = options
            end

            # @return [String, nil] the command line to run when the mint would go ahead
            def call
              Store.reading(@held) { |lineage, db| inspect_store(lineage, db) }
            end

            private

            def inspect_store(lineage, db)
              eras = []
              answer = nil
              @report.check("eras") do
                eras, answer = resolve(lineage)
                [:pass, resolved_words(answer)]
              end
              watermark = WatermarkGuards.new(@report, db, lineage)
              edge = proceed(lineage, eras, answer) if answer
              watermark.call(**ref_options)
              line(answer, eras, watermark) if edge
            end

            def resolve(lineage)
              eras = @held.held_eras(lineage)
              raise Runtime::WiringError, "#{@held.domain_name} holds no era; hold the first era before a mint" if eras.empty?

              named = [*eras[0...-1], @held.named(eras.last)]
              [eras, PostgresEra::LineageManager::RevisionResolution.resolve(
                eras: named, bluebook: @held.bluebook, translations: @held.translations, directory: @held.directory
              ) { lineage.last_ordinal }]
            end

            def resolved_words(answer)
              "#{answer.status}: #{answer.reason || "the latest era holds the current shape"} " \
                "(#{answer.held_count} era(s) held)"
            end

            def proceed(lineage, eras, answer)
              return held_shape(answer) unless %w[behind unminted].include?(answer.status)

              verdict = answer.verdict
              @report.add("decision", :info, "#{verdict.verdict}#{": #{verdict.reason}" if verdict.reason} (#{answer.status})")
              EdgeGuards.new(@report, @held, lineage).call(eras, verdict)
            end

            # The mint refuses a shape an era already holds; a current shape is no change at all.
            def held_shape(answer)
              @report.skip(LATER, "no mint: the shape is held")
              return @report.settle("no_change") && nil if answer.status == "current"

              @report.add("held_shape", :refuse, answer.reason)
              nil
            end

            def ref_options
              { ref: @options[:rehearsal_ref], watermark: @options[:rehearsal_watermark], verdict: @options[:rehearsal_verdict] }
            end

            def line(answer, eras, watermark)
              return if @report.refused?

              CommandLine.new(@held, answer.verdict, @held.named(eras.last), watermark.live).to_s
            end
          end
        end
      end
    end
  end
end
