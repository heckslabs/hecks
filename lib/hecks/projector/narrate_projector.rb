require_relative "docs_projector"
require_relative "../forms/field_shape"

module Hecks
  module Projector
    # A bluebook projected as prose an SME can read back and confirm.
    # Every sentence quotes a declared `description`, `goal` or `given`; nothing is invented.
    module NarrateProjector
      module_function

      # Projects `bluebook` as prose; `options[:heading]` sets the top heading level.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to narrate
      # @param options [Hash] `:heading` (Integer, default 1) and `:aggregate` (narrows to one
      #   aggregate, omitting the chapter intro and reactions)
      # @return [String] Markdown prose ending in a newline
      # @raise [Runtime::NotFound] if `options[:aggregate]` names no declared aggregate
      def call(bluebook:, options: {})
        depth = (options[:heading] || 1).to_i
        only  = options[:aggregate]

        sections = []
        sections << chapter_intro(bluebook, depth) unless only
        sections.concat(aggregate_narratives(bluebook, only, only ? depth : depth + 1))
        sections << Reactions.narrative(bluebook, depth + 1) unless only
        "#{sections.compact.join("\n\n").rstrip}\n"
      end

      # One narrative per aggregate, at heading level `depth`.
      def aggregate_narratives(bluebook, only, depth)
        Array(DocsProjector.aggregates(bluebook, only)).map { |aggregate| aggregate_narrative(aggregate, depth) }
      end

      def chapter_intro(bluebook, depth)
        names = bluebook.aggregates.map(&:hecks_name)
        parts = [DocsProjector.h(depth, bluebook.name), bluebook.vision, chapter_meta(bluebook)]
        parts << "It's told through #{to_sentence_list(names)}." unless names.empty?
        parts.compact.join("\n\n")
      end

      # The chapter's classification and former name as one paragraph, or `nil` when it has neither.
      def chapter_meta(bluebook)
        meta = []
        meta << "This is a #{bluebook.classification} domain." if bluebook.classification
        meta << "It was formerly known as `#{bluebook.formerly_known_as}`." if bluebook.formerly_known_as
        meta.join(" ") unless meta.empty?
      end

      def aggregate_narrative(aggregate, depth)
        entities = aggregate.entities.map { |entity| entity_narrative(aggregate, entity, depth + 1) }
        [DocsProjector.h(depth, aggregate.hecks_name), *aggregate_facts(aggregate),
         lifecycle_narrative(aggregate), Commands.verbs_narrative(aggregate, depth + 1),
         queries_narrative(aggregate.queries, aggregate.hecks_name, depth + 1), *entities].compact.join("\n\n")
      end

      # What an aggregate says of itself: its description, identity and references.
      def aggregate_facts(aggregate)
        [aggregate.description, identity_sentence(aggregate), references_sentence(aggregate)]
      end

      # The sentence naming the records an aggregate is linked to, or `nil` when it has none.
      def references_sentence(aggregate)
        refs = aggregate.attributes.select(&:reference?)
        return nil if refs.empty?

        targets = refs.map { |r| "#{a_or_an(r.type.target_name)} #{r.type.target_name}" }
        "Each one is linked to #{to_sentence_list(targets)}."
      end

      def identity_sentence(holder)
        return nil if holder.identity_heads.empty?

        "Every #{holder.hecks_name} is identified by its #{to_sentence_list(holder.identity_heads.map { |h| "`#{h}`" })}."
      end

      def entity_narrative(aggregate, entity, depth)
        [DocsProjector.h(depth, "#{entity.hecks_name} (within #{aggregate.hecks_name})"), entity.description,
         "Reached through its #{aggregate.hecks_name} — you address it by the #{aggregate.hecks_name}'s " \
         "id together with its own `#{entity.identity_heads.join("`, `")}`.",
         lifecycle_narrative(entity), Commands.verbs_narrative(entity, depth + 1),
         queries_narrative(entity.queries, entity.hecks_name, depth + 1)].compact.join("\n\n")
      end

      def lifecycle_narrative(holder)
        lifecycle = holder.lifecycle or return nil

        sentences = ["It carries a `#{lifecycle.field}`, starting out at `#{lifecycle.default}`."]
        lifecycle.transitions.each do |name, transition|
          froms = Array(transition.from).map { |f| "`#{f}`" }
          sentences << "**#{name}** moves it from #{to_sentence_list(froms, conj: "or")} to `#{transition.target}`."
        end
        sentences << "A verb not listed here can be issued from any state."
        sentences.join(" ")
      end

      def queries_narrative(queries, holder_name, depth)
        return nil if queries.empty?

        header = DocsProjector.h(depth, "Questions you can ask about #{a_or_an(holder_name)} #{holder_name}")
        "#{header}\n\n#{queries.map { |query| query_line(query) }.join("\n")}"
      end

      # One question as a bullet: its name, what it is given, its description and its filters.
      def query_line(query)
        shape = query.to_h
        sentence = "- **#{query.hecks_name}**#{given_clause(shape)}"
        sentence << " — #{query.description}" if query.description
        sentence << "." unless sentence.end_with?(".")
        sentence << filter_clause(shape)
      end

      # " (given a, b)" for a question that takes arguments, else nothing.
      def given_clause(shape)
        takes = Array(shape[:attributes]).map { |a| Forms::Humanize.label(a[:name].to_s).downcase }
        takes.empty? ? "" : " (given #{to_sentence_list(takes)})"
      end

      # " Only where ..." for a question that filters, else nothing.
      #
      # `w[:value]` is already `Literal.render`ed (quoted), so no `.inspect`.
      def filter_clause(shape)
        filters = Array(shape[:wheres]).map { |w| "`#{w[:field]}` #{op_words(w[:op])} #{w[:value]}" }
        filters.empty? ? "" : " Only where #{to_sentence_list(filters)}."
      end

      def op_words(comparator)
        { eq: "is", lt: "under", lte: "at most", gt: "over", gte: "at least" }[comparator.to_s.to_sym] || comparator.to_s
      end

      def to_sentence_list(items, conj: "and") = Naming.to_sentence_list(items, conj: conj)

      # Picks the article for `word`.
      #
      # @return [String] `"a"` or `"an"`
      def a_or_an(word) = Naming.a_or_an(word)
    end
  end
end

require_relative "narrate_projector/commands"
require_relative "narrate_projector/reactions"
