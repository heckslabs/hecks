module Hecks
  module Doc
    # The prose regions a page declares in its own text, one marker comment each, placed above the
    # words it describes:
    #
    #   <!-- prose anchor="Concept" purpose="concept"
    #        mentions="aggregate:Landing command:Landing.land!"
    #        supports="doc:docs/decisions/0163-….md code_file:lib/hecks/hecks/deliver.bluebook" -->
    #
    # The page owns its markers: the Docs boot is rebuilt from them on every read, so no other
    # place holds what a prose region claims. A marker whose purpose, mention kind or support kind
    # the Docs bluebook does not allow is refused here, naming the page.
    module ProseMarkers
      # One marker comment, its attributes as `name="value"` pairs.
      MARKER = /<!-- prose (.*?)-->/m

      # One `name="value"` attribute of a marker.
      ATTRIBUTE = /(\w+)="([^"]*)"/

      # What the words are for, as `Prose.Purpose` allows.
      PURPOSES = %w[concept why tutorial warning].freeze

      # The kinds of model term a mention names, as `Prose.MentionKind` allows.
      MENTION_KINDS = %w[verb aggregate command keyword route adr].freeze

      # The kinds of thing words rest on, as `Prose.SupportKind` allows.
      SUPPORT_KINDS = %w[bluebook_node ir_element code_file doc].freeze

      # One prose region: the Page command that adds it, and the Prose commands that say what it
      # claims.
      Region = Data.define(:anchor, :purpose, :mentions, :supports) do
        # @param path [String] the page
        # @return [Array(String, Hash)] the Page command that adds the region
        def command(path) = ["Docs::Page.AddProse", { page: path, anchor: { value: anchor } }]

        # @param path [String] the page
        # @return [String] the region's Prose key, `<path>#<anchor>`
        def key(path) = "#{path}##{anchor}"

        # @param path [String] the page
        # @return [Array<Array(String, Hash)>] Prose.Write, then a Mention and an AddSupport each
        def follow_ups(path)
          [["Docs::Prose.Write", { prose: { value: key(path) }, page: path, anchor: { value: anchor },
                                   purpose: { value: purpose } }],
           *pairs(path, "Mention", :term, mentions), *pairs(path, "AddSupport", :target, supports)]
        end

        private

        def pairs(path, verb, field, list)
          list.map { |kind, value| ["Docs::Prose.#{verb}", { prose: key(path), kind: { value: kind }, field => { value: value } }] }
        end
      end

      module_function

      # @param path [String] the page, as named in a refusal
      # @param text [String] its words
      # @return [Array<Region>] each prose region it marks, in reading order
      # @raise [ArgumentError] naming the page, when a marker breaks the Docs bluebook's rules
      def read(path, text)
        text.scan(MARKER).map { |(body)| region(path, body.scan(ATTRIBUTE).to_h) }
      end

      # @return [Region] one marker's region, once its kinds are allowed
      def region(path, fields)
        anchor = fields.fetch("anchor") { refuse(path, "a prose marker names no anchor") }
        purpose = allowed(path, anchor, "purpose", fields["purpose"].to_s, PURPOSES)
        Region.new(anchor, purpose, typed(path, anchor, fields["mentions"], MENTION_KINDS),
                   typed(path, anchor, fields["supports"], SUPPORT_KINDS))
      end

      # @return [Array<Array(String, String)>] each `kind:value` word as a pair, its kind allowed
      def typed(path, anchor, words, kinds)
        words.to_s.split.map do |word|
          kind, value = word.split(":", 2)
          [allowed(path, anchor, "kind", kind, kinds), value.to_s]
        end
      end

      # @return [String] the value, when it is one of `allowed`
      # @raise [ArgumentError] naming the page and the anchor, when it is not
      def allowed(path, anchor, what, value, allowed)
        return value if allowed.include?(value)

        refuse(path, "prose #{anchor.inspect} has #{what} #{value.inspect}, not one of #{allowed.join(", ")}")
      end

      # @raise [ArgumentError] always, naming the page
      def refuse(path, why) = raise(ArgumentError, "#{path}: #{why}")
    end
  end
end
