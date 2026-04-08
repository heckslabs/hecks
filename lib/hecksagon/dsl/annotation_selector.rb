# Hecksagon::DSL::AnnotationSelector
#
# Returned by HecksagonBuilder's method_missing when a PascalCase name is
# used at the top level (e.g. +Chat+). Chains to AnnotationApplier for
# attribute-level annotations with keyword options.
#
#   # Inside a Hecksagon block:
#   Chat.prompt.ai_responder adapter: :claude, emits: "Replied"
#
#   # Produces annotation:
#   { aggregate: "Chat", attribute: "prompt", annotation: :ai_responder,
#     adapter: :claude, emits: "Replied" }
#
module Hecksagon
  module DSL
    class AnnotationSelector
      def initialize(annotations, aggregate_name)
        @annotations = annotations
        @aggregate_name = aggregate_name
      end

      # PascalCase names qualify the path (e.g. Collaboration.Agent).
      # Lowercase names select the attribute and return an applier.
      #
      # @return [AnnotationSelector, AnnotationApplier]
      def method_missing(name, *args)
        if name.to_s.match?(/\A[A-Z]/)
          AnnotationSelector.new(@annotations, "#{@aggregate_name}::#{name}")
        else
          AnnotationApplier.new(@annotations, @aggregate_name, name.to_s)
        end
      end

      def respond_to_missing?(_, _ = false) = true
    end

    # Captures the annotation name and keyword options, pushes into the
    # shared annotations array.
    #
    #   Chat.prompt.ai_responder adapter: :claude, emits: "Replied"
    #
    class AnnotationApplier
      def initialize(annotations, aggregate, attribute)
        @annotations = annotations
        @aggregate = aggregate
        @attribute = attribute
      end

      def method_missing(annotation_name, **opts)
        @annotations << {
          aggregate: @aggregate,
          attribute: @attribute,
          annotation: annotation_name.to_sym
        }.merge(opts)
        self
      end

      def respond_to_missing?(_, _ = false) = true
    end
  end
end
