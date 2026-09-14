module RustProjection
  module Projector
    module_function

    # A SKIP DECISION, CARRYING THE CONSTRUCT FAMILY THAT FORCED IT.
    #
    # Every `*_skip_reason` in this generator answers `nil` (generate it)
    # or one of these. It IS the reason text (a String subclass), so every
    # existing reader — `puts "skipping #{verb}: #{reason}"`, a spec's
    # `include("kind: string")`, the manifest's own `reason` field — keeps
    # reading exactly the text it always read. What it adds is `construct`:
    # a short, machine-readable family name (`reference_hop_where`,
    # `optional_source`, `rootless`, ...) set by the SAME branch that wrote
    # the text, at the moment that branch decided.
    #
    # WHY THIS EXISTS (Phase 4 of the exclusions-to-inclusions plan): the
    # differential fuzzer used to learn "Rust didn't generate this" by
    # substring-matching Rust's refusal wording, and `bin/rust_coverage`
    # used to allowlist gaps by regexing this reason text. Both now read
    # `construct` off `manifest.json` instead, so the prose here is free to
    # change and a new, undeclared kind of skip can't hide behind a
    # familiar-looking message.
    #
    # A wrapper that re-words an inner reason (`"eligible head X's own
    # #{reason}"`) must keep the inner construct — `reskip` does that;
    # plain string interpolation would silently drop it back to a String.
    class SkipReason < String
      attr_reader :construct

      def initialize(construct, text)
        raise ArgumentError, "a skip reason needs a construct family" if construct.to_s.empty?

        super(text)
        @construct = construct.to_s.freeze
      end
    end

    def skip(construct, text) = SkipReason.new(construct, text)

    # `inner`'s own construct, re-worded. Falls back to `fallback` only when
    # `inner` is a plain String from somewhere that never set one.
    def reskip(inner, text, fallback: nil)
      construct = inner.respond_to?(:construct) ? inner.construct : fallback
      SkipReason.new(construct, text)
    end
  end
end
