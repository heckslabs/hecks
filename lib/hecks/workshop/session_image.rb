# Hecks::Workshop::SessionImage
#
# Captures a point-in-time snapshot of a Workshop's state so it can be
# saved to disk and later restored. The image records the domain name,
# aggregate definitions (serialized as DSL source), custom verbs, and
# a timestamp.
#
# Restoring an image rebuilds the Workshop's aggregate builders from
# the captured DSL, putting it back in sketch mode with the same
# definitions that were saved.
#
#   image = SessionImage.capture(workshop)
#   image.domain_name   # => "Pizzas"
#   image.dsl_source    # => 'Hecks.bluebook "Pizzas" do ...'
#
#   # Later...
#   image.restore_into(workshop)
#
module Hecks
  class Workshop
    class SessionImage
      attr_reader :domain_name, :dsl_source, :custom_verbs, :captured_at

      # Capture the current state of a workshop into an image.
      #
      # @param workshop [Hecks::Workshop] the workshop to snapshot
      # @return [SessionImage] a frozen image of the workshop state
      def self.capture(workshop)
        new(
          domain_name:  workshop.name,
          dsl_source:   DslSerializer.new(workshop.to_domain).serialize,
          custom_verbs: workshop.to_domain.custom_verbs.dup,
          captured_at:  Time.now
        )
      end

      # Create a SessionImage from its component parts.
      #
      # @param domain_name [String] the domain name
      # @param dsl_source [String] the DSL source code
      # @param custom_verbs [Array<String>] registered custom verbs
      # @param captured_at [Time] when the image was captured
      def initialize(domain_name:, dsl_source:, custom_verbs:, captured_at:)
        @domain_name  = domain_name
        @dsl_source   = dsl_source
        @custom_verbs = custom_verbs
        @captured_at  = captured_at
      end

      # Restore this image's state into a workshop.
      #
      # Clears the workshop's current aggregate builders and replaces them
      # with builders reconstructed from the saved DSL source. Puts the
      # workshop back into sketch mode.
      #
      # @param workshop [Hecks::Workshop] the workshop to restore into
      # @return [Hecks::Workshop] the restored workshop
      def restore_into(workshop)
        domain = eval(@dsl_source) # rubocop:disable Security/Eval
        workshop.aggregate_builders.clear

        domain.aggregates.each do |agg|
          workshop.aggregate_builders[agg.name] =
            DSL::AggregateRebuilder.from_aggregate(agg)
        end

        workshop
      end

      # Return a compact string representation.
      #
      # @return [String]
      def inspect
        agg_count = count_aggregates
        "#<SessionImage \"#{@domain_name}\" (#{agg_count} aggregates) at #{@captured_at}>"
      end

      private

      # Count aggregates by parsing the DSL source (avoids eval).
      #
      # @return [Integer]
      def count_aggregates
        @dsl_source.scan(/^\s*aggregate\s+"/).size
      end
    end
  end
end
