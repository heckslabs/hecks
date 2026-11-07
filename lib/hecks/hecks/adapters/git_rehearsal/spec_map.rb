# frozen_string_literal: true

require_relative "spec_map/corpus"
require_relative "spec_map/needles"

module Hecks
  module Adapters
    class GitRehearsal
      # Maps the files a push changes to the spec files that exercise them: conservatively and
      # cheaply, by name and by text, with no index and no dependency beyond the standard library.
      #
      # A changed spec runs itself. A changed Ruby file runs the spec named for it and the specs
      # that require it or mention its path or its constant. A changed bluebook, hecksagon, world or
      # behaviors file runs the specs that mention its path or domain name (and, for the language's
      # own bluebooks, the shape-ledger, conformance, corpus, golden and vocabulary specs). A changed
      # `rust/` file runs the Ruby specs that drive it, never cargo; a changed `docs/` file runs the
      # docs specs.
      class SpecMap
        # What was mapped.
        #
        # @!attribute [r] specs
        #   @return [Array<String>] the specs to run, closest first, at most the limit
        # @!attribute [r] total
        #   @return [Integer] how many specs the change maps to once skipped ones are left out
        # @!attribute [r] skipped
        #   @return [Hash{String => String}] each spec left out and why
        Mapping = Struct.new(:specs, :total, :skipped) do
          # @return [Boolean] whether the limit left specs out
          def capped? = total > specs.size

          # @return [String] how many ran and that the rest run in CI; empty when none were left out
          def cap_note = capped? ? "capped at #{specs.size} of #{total}; the rest run in CI" : ""
        end

        # The spec families a changed `docs/` file and a changed `rust/` file run.
        DOCS = %w[docs_ reference_ changelog_ adr_].freeze
        RUST = %w[rust_ semantics_corpus_spec].freeze
        LANGUAGE = %r{\Alib/hecks/language/}
        LEDGER = /shape_ledger|conformance|corpus|golden|vocabulary/
        EXTENSIONS = /\..*\z/

        # @param root [String] the tree whose `spec/` is searched
        def initialize(root)
          @root = root
          @corpus = Corpus.new(root)
        end

        # @param changed [Array<String>] changed paths relative to the root
        # @param limit [Integer] the most specs to return
        # @param skip [#call] given a spec, nil to run it or the reason to leave it out
        # @return [Mapping]
        def map(changed, limit:, skip: ->(_spec) {})
          ranked = tiers(changed).sort_by { |spec, tier| [tier, spec] }.map(&:first)
          reasons = ranked.to_h { |spec| [spec, skip.call(spec)] }.compact
          kept = ranked - reasons.keys
          Mapping.new(kept.first(limit), kept.size, reasons)
        end

        private

        # The closest tier each spec is reached at: 0 itself, 1 named for the file, 2 mentions it.
        def tiers(changed)
          changed.each_with_object({}) do |path, found|
            reach(path).each { |spec, tier| found[spec] = [found[spec], tier].compact.min }
          end
        end

        def reach(path)
          return { path => 0 } if itself?(path)

          found = named(path).to_h { |spec| [spec, 1] }
          found.merge!(mentioning(path).to_h { |spec| [spec, 2] }) { |_spec, near, _far| near }
          families(path).each { |spec| found[spec] ||= 3 }
          found
        end

        def itself?(path) = path.end_with?("_spec.rb") && File.exist?(File.join(@root, path))

        def named(path)
          wanted = "#{File.basename(path).sub(EXTENSIONS, "")}_spec.rb"
          @corpus.files.select { |spec| File.basename(spec) == wanted }
        end

        def mentioning(path)
          return [] if path.start_with?("docs/", "rust/")

          needles = Needles.new(File.join(@root, path), path)
          return [] if needles.none?

          @corpus.files.select { |spec| needles.match?(@corpus.text(spec)) }
        end

        def families(path)
          return starting(DOCS) if path.start_with?("docs/")
          return starting(RUST) if path.start_with?("rust/")

          path.match?(LANGUAGE) && Needles::DOMAIN.match?(path) ? @corpus.files.grep(LEDGER) : []
        end

        def starting(prefixes)
          @corpus.files.select { |spec| prefixes.any? { |prefix| File.basename(spec).start_with?(prefix) } }
        end
      end
    end
  end
end
