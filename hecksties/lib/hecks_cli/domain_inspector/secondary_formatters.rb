# Hecks::CLI::DomainInspector::SecondaryFormatters
#
# Formatting helpers for less-common aggregate IR sections: scopes,
# specifications, subscribers, references, and computed attributes.
# Mixed into AggregateFormatter to keep the main file under 200 lines.
#
#   include SecondaryFormatters
#
module Hecks
  class CLI
    class DomainInspector
      module SecondaryFormatters
        private

        def format_computed_attributes
          return [] if (@agg.computed_attributes || []).empty?
          lines = ["  Computed Attributes:"]
          @agg.computed_attributes.each do |ca|
            body = Hecks::Utils.block_source(ca.block)
            lines << "    #{ca.name}: #{body}"
          end
          lines << ""
        end

        def format_scopes
          return [] if @agg.scopes.empty?
          lines = ["  Scopes:"]
          @agg.scopes.each { |s| lines << "    #{s.name}" }
          lines << ""
        end

        def format_specifications
          return [] if @agg.specifications.empty?
          lines = ["  Specifications:"]
          @agg.specifications.each do |s|
            body = Hecks::Utils.block_source(s.block)
            lines << "    #{s.name}: #{body}"
          end
          lines << ""
        end

        def format_subscribers
          return [] if @agg.subscribers.empty?
          lines = ["  Subscribers:"]
          @agg.subscribers.each do |s|
            async_note = s.async ? " [async]" : ""
            body = Hecks::Utils.block_source(s.block)
            lines << "    #{s.name}: on #{s.event_name}#{async_note} — #{body}"
          end
          lines << ""
        end

        def format_references
          return [] if @agg.references.empty?
          lines = ["  References:"]
          @agg.references.each do |ref|
            kind = ref.respond_to?(:kind) && ref.kind ? " (#{ref.kind})" : ""
            lines << "    -> #{ref.type}#{kind}"
          end
          lines << ""
        end
      end
    end
  end
end
