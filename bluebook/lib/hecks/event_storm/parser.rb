Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::AstParagraph,
  base_dir: File.expand_path("parser", __dir__)
)

module Hecks
  module EventStorm
    # Hecks::EventStorm::Parser
    #
    # Parses an ASCII event storm document into a structured intermediate
    # representation. Recognizes bounded contexts, commands, events, aggregates,
    # policies, actors, read models, external systems, and hotspots.
    #
    # The notation uses bracket shapes to encode concept types:
    #   >>Event<<  [Command]  (Aggregate)  {When X, Y}  <ReadModel>
    #   [[External]]  Actor: Name  !!Hotspot!!
    #
    # Pattern matching logic lives in Parser::PatternMatching; context splitting
    # and element grouping live in Parser::ContextGrouping.
    #
    #   parser = Parser.new(File.read("storm.md"))
    #   result = parser.parse
    #   result.contexts.first.name  # => "Ordering"
    #
    class Parser
      include PatternMatching
      include ContextGrouping

      # Regular expression patterns for each event storm concept type.
      # Used by PatternMatching#parse_line to identify elements in text.
      #
      # - :domain    -- top-level heading (# Domain Name)
      # - :context   -- bounded context heading (## Bounded Context: Name)
      # - :event     -- domain event (>>EventName<<)
      # - :command   -- command ([CommandName])
      # - :aggregate -- aggregate ((AggregateName))
      # - :policy    -- reactive policy ({When Event, Action})
      # - :read_model -- read model (<ModelName>)
      # - :external  -- external system ([[SystemName]])
      # - :actor     -- actor (Actor: Name)
      # - :hotspot   -- discussion hotspot (!!Issue!!)
      PATTERNS = {
        domain:    /^#\s+(.+?)(?:\s*[-—=]+.*)?$/,
        context:   /^##\s+Bounded Context:\s*(.+)$/,
        event:     />>(.+?)<</,
        command:   /\[([^\[\]]+)\]/,
        aggregate: /\(([^()]+)\)/,
        policy:    /\{When\s+(.+?),\s*(.+?)\}/,
        read_model: /<([^<>]+)>/,
        external:  /\[\[(.+?)\]\]/,
        actor:     /^[\s|v+\->]*Actor:\s*(.+)$/,
        hotspot:   /!!(.+?)!!/,
      }.freeze

      # Struct representing the full parse result from an event storm document.
      #
      # @!attribute domain_name [String, nil] the domain name extracted from the top heading
      # @!attribute contexts [Array<ParsedContext>] bounded contexts with their elements
      # @!attribute warnings [Array<String>] any warnings generated during parsing
      ParseResult = Struct.new(:domain_name, :contexts, :warnings, keyword_init: true)

      # Struct representing a single bounded context within a parse result.
      #
      # @!attribute name [String] the context name (e.g., "Ordering", "Default")
      # @!attribute elements [Array<ParsedElement>] all elements found in this context
      ParsedContext = Struct.new(:name, :elements, keyword_init: true)

      # Struct representing a single parsed element (command, event, policy, etc.).
      #
      # @!attribute type [Symbol] one of :command, :event, :policy, :aggregate,
      #   :actor, :read_model, :external, :hotspot
      # @!attribute name [String] the element's name (PascalCase, normalized)
      # @!attribute meta [Hash] additional metadata (e.g., :aggregate, :read_models,
      #   :external_systems, :event_name, :trigger)
      ParsedElement = Struct.new(:type, :name, :meta, keyword_init: true)

      # Initializes a new Parser with source text.
      #
      # @param source [String] the ASCII event storm document to parse
      def initialize(source)
        @source = source
        @warnings = []
      end

      # Parses the source text into a structured ParseResult.
      #
      # Splits the document into lines, extracts the domain name from the
      # top-level heading, splits into bounded contexts, and parses each
      # context's elements.
      #
      # @return [ParseResult] the structured parse result containing domain_name,
      #   contexts, and warnings
      def parse
        lines = @source.lines.map(&:rstrip)
        domain_name = extract_domain_name(lines)
        contexts = extract_contexts(lines)

        ParseResult.new(domain_name: domain_name, contexts: contexts, warnings: @warnings)
      end
    end
  end
end
