# frozen_string_literal: true

module Hecks
  module Adapters
    module Rehearsal
      # What the mint's audit read and what it concluded, as the facts the report holds: how much
      # was examined by each engine, whether anything was, why not when nothing was, and how the
      # two engines stood against each other.
      class AuditReport
        # The limit a clean verdict carries when no stored row was read.
        UNAUDITED = "the stored rows"

        # The wording that explains a Rust-only refusal: the Ruby audit's first layer does not hold
        # a stored value to a closed set, a required field or an undeclared value-object key.
        RUST_ONLY = "The Rust audit also holds a stored value to its closed set, a required field and an " \
                    "undeclared value-object key, which the Ruby audit's first layer does not yet: a row " \
                    "only Rust refuses is that known difference between the engines, not a second finding."

        # @param minting [String] none, first or next
        # @param edge [Bluebook::Translation, nil] the edge the audit ran through
        # @param states [Hash{String => Hash}] the translated records the audit read, by aggregate
        # @param ruby [Array<String>] the Ruby audit's refusals
        # @param rust [RustAudit::Result] the second engine's answer
        def initialize(minting:, edge:, states:, ruby:, rust:)
          @minting = minting
          @edge = edge
          @states = states
          @ruby = ruby
          @rust = rust
        end

        # @return [Boolean] whether any stored row was read by the audit
        def audited? = !@edge.nil? && @minting == "next"

        # @return [Integer] the rows the Ruby audit read
        def rows = @states.values.sum(&:size)

        # @return [Hash] `audited`, `rows_examined`, `aggregates_examined`, `rust_rows_examined`
        #   (zero when the second engine did not run, which `parity` says) and the sentence the
        #   verdict rests on
        def facts
          { audited: flag(audited?), rows_examined: count(rows), reason: { value: reason },
            aggregates_examined: count(aggregates),
            rust_rows_examined: count(@rust.rows) }
        end

        # @return [Hash] the Rust engine's standing against the Ruby one, with who refused what
        def parity
          return { engine: "rust", status: "not_run", note: @rust.note } unless @rust.ran
          return { engine: "rust", status: "agree", note: agreed } if ruby_records == rust_records

          { engine: "rust", status: "differ", note: differed }
        end

        # @return [Array<Hash>] the limit a rehearsal that read nothing carries
        def limits = audited? ? [] : [{ what: UNAUDITED, why: reason }]

        private

        def flag(value) = { value: value }

        def count(value) = { value: value }

        def reason
          case @minting
          when "none" then "no mint is needed at this shape, so no stored row was examined"
          when "first" then "no era is held, so the first mint holds the shape as it stands and no stored row was examined"
          else next_reason
          end
        end

        def next_reason
          return "no edge leads the held era to this shape, so no stored row was examined" unless @edge

          "the audit read #{rows} stored row(s) of #{aggregates} aggregate(s) through the edge " \
            "#{@edge.from} -> #{@edge.to}"
        end

        def aggregates = @states.count { |_, held| held.any? }

        def ruby_records = records(@ruby)

        def rust_records = records(@rust.violations)

        def records(refusals) = refusals.map { |text| text[/\A[^:]+/] }.uniq.sort

        def agreed = "ruby refused #{ruby_records.size} records, rust #{rust_records.size}; rust read #{@rust.rows} rows"

        def differed
          rust_only = rust_records - ruby_records
          ruby_only = ruby_records - rust_records
          "the engines refused different records: ruby #{ruby_records.size}, rust #{rust_records.size}. " \
            "#{only("rust", rust_only)}#{only("ruby", ruby_only)}#{known_gap(rust_only)}" \
            "Both are held against the report: the union is refused."
        end

        def known_gap(rust_only) = rust_only.empty? ? "" : "#{RUST_ONLY} "

        def only(engine, held)
          return "" if held.empty?

          "Only #{engine} refused: #{held.first(5).join(", ")}#{", ..." if held.size > 5}. "
        end
      end
    end
  end
end
