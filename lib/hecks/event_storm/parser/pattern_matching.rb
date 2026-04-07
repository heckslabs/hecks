module Hecks
  module EventStorm
    class Parser
      # Hecks::EventStorm::Parser::PatternMatching
      #
      # Mixin that provides pattern matching and line-parsing logic for the event
      # storm parser. Identifies actors, commands, events, policies, aggregates,
      # read models, external systems, and hotspots from individual text lines.
      #
      # Architecture: included by Hecks::EventStorm::Parser. Relies on the host
      # class defining PATTERNS and ParsedElement.
      #
      #   parsed = parse_line("Actor: Chef  [PlacePizza] >>PizzaPlaced<<")
      #   parsed[:command].name  # => "PlacePizza"
      #
      module PatternMatching
        private

        # Parses a single cleaned line of event storm text into recognized elements.
        #
        # Applies each pattern in order, with disambiguation logic to avoid
        # false positives (e.g., external [[...]] vs command [...], aggregate
        # (...) vs read model <...>). A single line can produce multiple element
        # types (e.g., an actor, a command, and an event on the same line).
        #
        # @param line [String] a cleaned line (leading whitespace/flow chars stripped)
        # @return [Hash<Symbol, ParsedElement>, nil] a hash of recognized elements
        #   keyed by type (:actor, :command, :event, :policy, :aggregate,
        #   :read_model, :external, :hotspot), or nil if nothing was recognized
        def parse_line(line)
          result = {}

          if (match = line.match(PATTERNS[:actor]))
            result[:actor] = ParsedElement.new(type: :actor, name: match[1].strip, meta: {})
          end

          if (match = line.match(PATTERNS[:policy]))
            result[:policy] = ParsedElement.new(
              type: :policy, name: normalize_name(match[2].strip),
              meta: { event_name: normalize_name(match[1].strip), trigger: normalize_name(match[2].strip) }
            )
          elsif (match = line.match(PATTERNS[:external]))
            result[:external] = ParsedElement.new(type: :external, name: match[1].strip, meta: {})
          end

          if !result[:policy] && !result[:external] && (match = line.match(PATTERNS[:command]))
            result[:command] = ParsedElement.new(type: :command, name: normalize_name(match[1].strip), meta: {})
          end

          if (match = line.match(PATTERNS[:event]))
            result[:event] = ParsedElement.new(type: :event, name: normalize_name(match[1].strip), meta: {})
          end

          if !result[:external] && (match = line.match(PATTERNS[:aggregate]))
            result[:aggregate] = ParsedElement.new(type: :aggregate, name: normalize_name(match[1].strip), meta: {})
          end

          if !result[:external] && !result[:aggregate] && (match = line.match(PATTERNS[:read_model]))
            result[:read_model] = ParsedElement.new(type: :read_model, name: match[1].strip, meta: {})
          end

          if (match = line.match(PATTERNS[:hotspot]))
            result[:hotspot] = ParsedElement.new(type: :hotspot, name: match[1].strip, meta: {})
          end

          result.empty? ? nil : result
        end

        # Normalizes a name by splitting on whitespace and capitalizing each word.
        #
        # Produces PascalCase identifiers from space-separated words.
        #
        # @param name [String] the raw name (e.g., "place order")
        # @return [String] the normalized PascalCase name (e.g., "PlaceOrder")
        def normalize_name(name)
          name.split(/\s+/).map(&:capitalize).join
        end

        # Extracts the domain name from the first top-level heading in the document.
        #
        # Skips blank lines and sub-headings (##). Returns nil if no heading is
        # found or if the heading is a LEGEND or separator line.
        #
        # @param lines [Array<String>] all document lines
        # @return [String, nil] the domain name, or nil if not found
        def extract_domain_name(lines)
          lines.each do |line|
            next if line.strip.empty? || line.start_with?("##")
            match = line.match(PATTERNS[:domain])
            return match[1].strip if match && !line.include?("LEGEND") && !line.include?("=====")
          end
          nil
        end
      end
    end
  end
end
