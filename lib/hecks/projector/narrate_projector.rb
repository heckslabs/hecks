require_relative "docs_projector"
require_relative "../forms/field_shape"

module Hecks
  module Projector
    # A bluebook, projected as prose an SME can read back and confirm.
    #
    # ## What this is for
    #
    # `DocsProjector` already answers "what can I call and what does it
    # want" for the person implementing against a domain — tables of
    # arguments, shapes, refusal reasons. That is the wrong register for
    # the person who can actually say whether the domain is right: the
    # subject-matter expert who knows what an account is and has never
    # read a markdown table in their life. This projects the same IR as
    # sentences instead — "Debit — take money out. Issued by a Teller.
    # It only goes through if the balance covers it." — so a domain can
    # be read back to the person who can validate it without them
    # learning the DSL first.
    #
    # Same source, same guarantee `DocsProjector` gives: nothing here is
    # invented. Every sentence quotes a `description`, `goal`, or `given`
    # already declared in the chapter; where a chapter says nothing, this
    # says nothing rather than manufacturing a sentence out of an
    # identifier. Registered as `:narrate` beside `:docs`, same call shape
    # (`Projector.call(:narrate, bluebook: ...)`), same aggregate-scoping
    # via `options[:aggregate]`.
    #
    # ## What it does not do
    #
    # Replace `DocsProjector`. A shape table still says "id of a
    # Customer" more precisely than any sentence would, and an
    # implementer still wants that. This is the other document the same
    # IR is owed — one written for the reader who is being asked "is
    # this right?", not "how do I call it?"
    module NarrateProjector
      module_function

      # Projects `bluebook` as prose an SME can read back and confirm.
      #
      # `options[:heading]` sets the top heading level, exactly as
      # `DocsProjector` does — so this, too, can be spliced into a larger
      # document rather than always starting at H1.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to narrate
      # @param options [Hash] optional inputs
      # @option options [Integer, String] :heading the top heading level; defaults to 1
      # @option options [String, Symbol, nil] :aggregate narrows the narrative to one
      #   aggregate, omitting the chapter intro and reactions sections
      # @return [String] the narrative, as Markdown prose, ending in a newline
      # @raise [Runtime::NotFound] if `options[:aggregate]` names no aggregate `bluebook`
      #   declares
      def call(bluebook:, options: {})
        depth = (options[:heading] || 1).to_i
        only  = options[:aggregate]

        sections = []
        sections << chapter_intro(bluebook, depth) unless only
        Array(DocsProjector.aggregates(bluebook, only)).each do |aggregate|
          sections << aggregate_narrative(aggregate, only ? depth : depth + 1)
        end
        sections << reactions_narrative(bluebook, depth + 1) unless only
        "#{sections.compact.join("\n\n").rstrip}\n"
      end

      # ── the chapter ───────────────────────────────────────────────────

      # Narrates the chapter-level intro: its vision, classification, former
      # name, and the aggregates it's told through.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to narrate
      # @param depth [Integer] the heading level for the chapter's own title
      # @return [String] the intro's Markdown prose
      def chapter_intro(bluebook, depth)
        parts = [DocsProjector.h(depth, bluebook.name)]
        parts << bluebook.vision if bluebook.vision

        meta = []
        meta << "This is a #{bluebook.classification} domain." if bluebook.classification
        meta << "It was formerly known as `#{bluebook.formerly_known_as}`." if bluebook.formerly_known_as
        parts << meta.join(" ") unless meta.empty?

        names = bluebook.aggregates.map(&:hecks_name)
        parts << "It's told through #{to_sentence_list(names)}." unless names.empty?
        parts.join("\n\n")
      end

      # ── one aggregate ─────────────────────────────────────────────────

      # Narrates one aggregate: its description, identity, references,
      # lifecycle, commands, queries, and nested entities.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate to narrate
      # @param depth [Integer] the heading level for the aggregate's own title
      # @return [String] the aggregate's Markdown prose
      def aggregate_narrative(aggregate, depth)
        parts = [DocsProjector.h(depth, aggregate.hecks_name)]
        parts << aggregate.description if aggregate.description
        parts << identity_sentence(aggregate)

        refs = aggregate.attributes.select(&:reference?)
        unless refs.empty?
          parts << "Each one is linked to #{to_sentence_list(refs.map do |r|
            "#{a_or_an(r.type.target_name)} #{r.type.target_name}"
          end)}."
        end

        parts << lifecycle_narrative(aggregate)
        parts << verbs_narrative(aggregate, depth + 1)
        parts << queries_narrative(aggregate.queries, aggregate.hecks_name, depth + 1)

        aggregate.entities.each { |entity| parts << entity_narrative(aggregate, entity, depth + 1) }
        parts.compact.join("\n\n")
      end

      # Names how a holder is identified.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the holder to describe
      # @return [String, nil] a sentence naming `holder`'s identity fields, or nil if
      #   it declares none
      def identity_sentence(holder)
        return nil if holder.identity_heads.empty?

        "Every #{holder.hecks_name} is identified by its #{to_sentence_list(holder.identity_heads.map { |h| "`#{h}`" })}."
      end

      # Narrates one entity nested under `aggregate`.
      #
      # @param aggregate [Bluebook::Aggregate] the entity's own owning aggregate
      # @param entity [Bluebook::Entity] the entity to narrate
      # @param depth [Integer] the heading level for the entity's own title
      # @return [String] the entity's Markdown prose
      def entity_narrative(aggregate, entity, depth)
        parts = [DocsProjector.h(depth, "#{entity.hecks_name} (within #{aggregate.hecks_name})")]
        parts << entity.description if entity.description
        parts << "Reached through its #{aggregate.hecks_name} — you address it by the #{aggregate.hecks_name}'s " \
                 "id together with its own `#{entity.identity_heads.join('`, `')}`."

        parts << lifecycle_narrative(entity)
        parts << verbs_narrative(entity, depth + 1)
        parts << queries_narrative(entity.queries, entity.hecks_name, depth + 1)
        parts.compact.join("\n\n")
      end

      # ── the machine ───────────────────────────────────────────────────

      # Narrates a holder's own lifecycle transitions.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the holder to describe
      # @return [String, nil] a sentence per lifecycle transition, or nil if `holder`
      #   declares no lifecycle
      def lifecycle_narrative(holder)
        lifecycle = holder.lifecycle or return nil

        sentences = ["It carries a `#{lifecycle.field}`, starting out at `#{lifecycle.default}`."]
        lifecycle.transitions.each do |name, transition|
          froms = Array(transition.from).map { |f| "`#{f}`" }
          sentences << "**#{name}** moves it from #{to_sentence_list(froms, conj: 'or')} to `#{transition.target}`."
        end
        sentences << "A verb not listed here can be issued from any state."
        sentences.join(" ")
      end

      # ── the verbs ─────────────────────────────────────────────────────

      # Narrates every command a holder declares.
      #
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the holder whose
      #   commands to narrate
      # @param depth [Integer] the heading level for the "What can happen" section
      # @return [String, nil] the section's Markdown prose, or nil if `holder`
      #   declares no command
      def verbs_narrative(holder, depth)
        return nil if holder.commands.empty?

        header = DocsProjector.h(depth, "What can happen to #{a_or_an(holder.hecks_name)} #{holder.hecks_name}")
        body   = holder.commands.map { |command| command_paragraph(command, holder) }.join("\n\n")
        "#{header}\n\n#{body}"
      end

      # One paragraph, built from independent sentences — each sentence
      # below states one unrelated fact about `command` (its goal, who
      # issues it, whether it creates the holder, what it takes, what it
      # references, what gates it, what it guarantees, what it emits), in
      # the fixed order a reader expects them; nothing after the first
      # sentence depends on anything before it. Same nil-or-string +
      # `compact.join` shape `aggregate_narrative`/`entity_narrative`
      # already use above for the identical reason.
      #
      # @param command [Bluebook::Command] the command to narrate
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] `command`'s own holder
      # @return [String] the command's own paragraph
      def command_paragraph(command, holder)
        [
          command_headline_sentence(command),
          command_role_sentence(command),
          command_creation_sentence(command, holder),
          command_arguments_sentence(command),
          command_references_sentence(command),
          command_conditions_sentence(command, holder),
          command_guarantees_sentence(command),
          command_emits_sentence(command)
        ].compact.join(" ")
      end

      # The goal, verbatim — same rule `DocsProjector` holds to: quoted
      # exactly as declared, not recased to fit mid-sentence, because the
      # promise this whole projector makes is that a sentence here is a
      # sentence the chapter actually wrote.
      #
      # @param command [Bluebook::Command] the command to name
      # @return [String] the command's own bold name, plus its goal if it declares one
      def command_headline_sentence(command)
        "**#{command.hecks_name}**#{command.goal ? " — #{command.goal}." : '.'}"
      end

      # Names who issues a command.
      #
      # @param command [Bluebook::Command] the command to describe
      # @return [String, nil] a sentence naming who issues `command`, or nil if it
      #   declares no role
      def command_role_sentence(command)
        return nil unless command.role

        "Issued by #{a_or_an(command.role)} #{command.role}."
      end

      # `acts_on.nil?`, not `creates?` — `creates?` answers true for every
      # verb an entity declares (it never references itself; see
      # `Command#acts_on`'s own comment), so reading it directly here would
      # tell an SME that `LedgerEntry.Amend` brings a new ledger entry into
      # being, which is exactly backwards.
      # @param command [Bluebook::Command] the command to check
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] `command`'s own holder
      # @return [String, nil] a sentence saying `command` creates `holder`, or nil if
      #   `command` acts on an existing record instead
      def command_creation_sentence(command, holder)
        return nil unless command.acts_on.nil?

        "This is how a new #{holder.hecks_name} comes into being."
      end

      # Lists a command's own non-reference arguments.
      #
      # @param command [Bluebook::Command] the command to describe
      # @return [String, nil] a sentence listing `command`'s non-reference arguments,
      #   or nil if it declares none
      def command_arguments_sentence(command)
        arguments = command.attributes.reject(&:reference?)
        return nil if arguments.empty?

        "It takes #{to_sentence_list(arguments.map { |a| Forms::Humanize.label(a.name.to_s).downcase })}."
      end

      # Names what a command references.
      #
      # @param command [Bluebook::Command] the command to describe
      # @return [String, nil] a sentence naming what `command` references, or nil if
      #   it declares no reference argument
      def command_references_sentence(command)
        refs = command.attributes.select(&:reference?)
        return nil if refs.empty?

        "It's aimed at one existing #{to_sentence_list(refs.map { |r| r.type.target_name })}, by id."
      end

      # Lists a command's own required conditions.
      #
      # @param command [Bluebook::Command] the command to describe
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] `command`'s own holder
      # @return [String, nil] a sentence listing every required condition, or nil if
      #   `command` declares none
      def command_conditions_sentence(command, holder)
        conditions = conditions_of(command, holder)
        return nil if conditions.empty?

        "It only goes through if #{conditions.join('; ')}."
      end

      # Lists what a command guarantees when it succeeds.
      #
      # @param command [Bluebook::Command] the command to describe
      # @return [String, nil] a sentence listing `command`'s own `ensures`, or nil if
      #   it declares none
      def command_guarantees_sentence(command)
        guarantees = command.ensures.map(&:description)
        return nil if guarantees.empty?

        "When it succeeds: #{guarantees.join('; ')}."
      end

      # Names what a command records.
      #
      # @param command [Bluebook::Command] the command to describe
      # @return [String, nil] a sentence naming what `command` records, or nil if it
      #   emits nothing
      def command_emits_sentence(command)
        return nil if command.emits.empty?

        "It records `#{command.emits.join('`, `')}` as a fact."
      end

      # Every required condition, stated as something that must be true —
      # the same three sources `DocsProjector#refusals_of` reads (the
      # lifecycle edge, a reference's existence, and the command's own
      # `given`s), but kept positive rather than phrased as a refusal
      # reason. "Refused unless not X" is a sentence a reader has to
      # invert in their head; "only goes through if X" is not.
      #
      # @param command [Bluebook::Command] the command to gather conditions for
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] `command`'s own holder
      # @return [Array<String>] every required condition, stated positively
      def conditions_of(command, holder)
        conditions = []

        lifecycle = holder.lifecycle
        if lifecycle
          froms = lifecycle.transitions.filter_map do |name, transition|
            Array(transition.from) if name.to_s == command.hecks_name
          end.flatten.uniq
          unless froms.empty?
            conditions << "its `#{lifecycle.field}` is currently #{to_sentence_list(froms.map do |f|
              "`#{f}`"
            end, conj: 'or')}"
          end
        end

        conditions + command.givens.map(&:description)
      end

      # ── the reads ─────────────────────────────────────────────────────

      # Narrates every query as one line per question.
      #
      # @param queries [Array<Bluebook::Query>] the queries to narrate
      # @param holder_name [String] the queries' own holder's name
      # @param depth [Integer] the heading level for the "Questions you can ask" section
      # @return [String, nil] the section's Markdown prose, or nil if `queries` is empty
      def queries_narrative(queries, holder_name, depth)
        return nil if queries.empty?

        header = DocsProjector.h(depth, "Questions you can ask about #{a_or_an(holder_name)} #{holder_name}")
        lines = queries.map do |query|
          shape   = query.to_h
          takes   = Array(shape[:attributes]).map { |a| Forms::Humanize.label(a[:name].to_s).downcase }
          # `w[:value]` already wears its own quotes or colon — it is a
          # `Literal.render`ed string (see lib/hecks/literal.rb), not a raw
          # Ruby value, so wrapping it in `.inspect` here would quote an
          # already-quoted string a second time.
          filters = Array(shape[:wheres]).map { |w| "`#{w[:field]}` #{op_words(w[:op])} #{w[:value]}" }

          sentence = "- **#{query.hecks_name}**"
          sentence << " (given #{to_sentence_list(takes)})" unless takes.empty?
          sentence << " — #{query.description}" if query.description
          sentence << "." unless sentence.end_with?(".")
          sentence << " Only where #{to_sentence_list(filters)}." unless filters.empty?
          sentence
        end
        "#{header}\n\n#{lines.join("\n")}"
      end

      # Translates a query comparator into plain English.
      #
      # @param comparator [String, Symbol] a where-clause comparator, such as `:eq`
      # @return [String] the comparator in plain words, or `comparator.to_s` verbatim
      #   for one this file has no rendering rule for
      def op_words(comparator)
        { eq: "is", lt: "under", lte: "at most", gt: "over", gte: "at least" }[comparator.to_s.to_sym] || comparator.to_s
      end

      # ── what happens on its own ───────────────────────────────────────

      # Narrates what happens on its own: every policy and every saga.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to narrate
      # @param depth [Integer] the heading level for the "Reactions" section
      # @return [String, nil] the section's Markdown prose, or nil if `bluebook`
      #   declares no policy and no process manager
      def reactions_narrative(bluebook, depth)
        return nil if bluebook.policies.empty? && bluebook.process_managers.empty?

        parts = [DocsProjector.h(depth, "Reactions")]
        bluebook.policies.each do |policy|
          elsewhere = policy.target_domain ? " in #{policy.target_domain}" : ""
          parts << "Whenever `#{policy.on_event}` happens, `#{policy.trigger_command}` fires on its own#{elsewhere} — " \
                   "nobody has to ask for it."
        end

        bluebook.process_managers.each do |saga|
          shape = saga.to_h
          parts << "**#{shape[:name]}** is a saga: it starts when `#{shape[:starts_on]}` happens and ends when " \
                   "`#{shape[:ends_on]}` happens, with each run tracked by its `#{shape[:correlates_by]}`. Along the " \
                   "way it moves through #{Array(shape[:states]).map { |s| "`#{s}`" }.join(' → ')}."
        end
        parts.join("\n\n")
      end

      # ── small sentence carpentry ──────────────────────────────────────

      # Both now live in `Naming` (a second projection, the glossary,
      # needed them); kept here as names so this file reads as it did.
      #
      # @param items [Array<#to_s>] items to join, in order
      # @param conj [String] conjunction placed before the last item
      # @return [String] the joined sentence fragment, `""` for an empty `items`
      def to_sentence_list(items, conj: "and") = Naming.to_sentence_list(items, conj: conj)

      # Picks the English indefinite article for a word.
      #
      # @param word [String, Symbol] the word the article precedes
      # @return [String] `"a"` or `"an"`
      def a_or_an(word) = Naming.a_or_an(word)
    end
  end
end
