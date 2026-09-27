module RustProjection
  module Projector
    module_function

    # A skip reason: the message text (a String) plus the machine-readable
    # `construct` family (`rootless`, `optional_source`, ...) that forced the skip.
    #
    # Consumers read `construct` from manifest.json, so the prose is free to change.
    # Re-wording an inner reason must go through `reskip`; interpolation drops `construct`.
    class SkipReason < String
      attr_reader :construct

      def initialize(construct, text)
        raise ArgumentError, "a skip reason needs a construct family" if construct.to_s.empty?

        super(text)
        @construct = construct.to_s.freeze
      end
    end

    def skip(construct, text) = SkipReason.new(construct, text)

    # Re-words `inner` while keeping its construct; `fallback` applies only to a plain String.
    def reskip(inner, text, fallback: nil)
      construct = inner.respond_to?(:construct) ? inner.construct : fallback
      SkipReason.new(construct, text)
    end
  end
end
