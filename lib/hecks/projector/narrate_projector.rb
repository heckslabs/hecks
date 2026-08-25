require_relative "docs_projector"
require_relative "../forms/field_shape"

module Hecks
  module Projector
    # A BLUEBOOK, PROJECTED AS PROSE AN SME CAN READ BACK AND CONFIRM.
    #
    # WHAT THIS IS FOR. `DocsProjector` already answers "what can I call and
    # what does it want" for the person implementing against a domain —
    # tables of arguments, shapes, refusal reasons. That is the wrong
    # register for the person who can actually say whether the domain is
    # RIGHT: the subject-matter expert who knows what an account is and has
    # never read a markdown table in their life. This projects the same IR
    # as sentences instead — "Debit — take money out. Issued by a Teller. It
    # only goes through if the balance covers it." — so a domain can be
    # read back to the person who can validate it without them learning the
    # DSL first.
    #
    # SAME SOURCE, SAME GUARANTEE `DocsProjector` gives: nothing here is
    # invented. Every sentence quotes a `description`, `goal`, or `given`
    # already declared in the chapter; where a chapter says nothing, this
    # says nothing rather than manufacturing a sentence out of an
    # identifier. Registered as `:narrate` beside `:docs`, same call shape
    # (`Projector.call(:narrate, bluebook: ...)`), same aggregate-scoping
    # via `options[:aggregate]`.
    #
    # WHAT IT DOES NOT DO: replace `DocsProjector`. A shape table still says
    # "id of a Customer" more precisely than any sentence would, and an
    # implementer still wants that. This is the other document the same IR
    # is owed — one written for the reader who is being asked "is this
    # right?", not "how do I call it?"
    module NarrateProjector
      module_function

      # `options[:heading]` sets the top heading level, exactly as
      # `DocsProjector` does — so this, too, can be spliced into a larger
      # document rather than always starting at H1.
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

      def aggregate_narrative(aggregate, depth)
        parts = [DocsProjector.h(depth, aggregate.hecks_name)]
        parts << aggregate.description if aggregate.description
        parts << identity_sentence(aggregate)

        refs = aggregate.attributes.select(&:reference?)
        parts << "Each one is linked to #{to_sentence_list(refs.map { |r| "#{a_or_an(r.type.target_name)} #{r.type.target_name}" })}." unless refs.empty?

        parts << lifecycle_narrative(aggregate)
        parts << verbs_narrative(aggregate, depth + 1)
        parts << queries_narrative(aggregate.queries, aggregate.hecks_name, depth + 1)

        aggregate.entities.each { |entity| parts << entity_narrative(aggregate, entity, depth + 1) }
        parts.compact.join("\n\n")
      end

      def identity_sentence(holder)
        return nil if holder.identity_heads.empty?

        "Every #{holder.hecks_name} is identified by its #{to_sentence_list(holder.identity_heads.map { |h| "`#{h}`" })}."
      end

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

      def verbs_narrative(holder, depth)
        return nil if holder.commands.empty?

        header = DocsProjector.h(depth, "What can happen to #{a_or_an(holder.hecks_name)} #{holder.hecks_name}")
        body   = holder.commands.map { |command| command_paragraph(command, holder) }.join("\n\n")
        "#{header}\n\n#{body}"
      end

      def command_paragraph(command, holder)
        # THE GOAL, VERBATIM — same rule `DocsProjector` holds to: quoted
        # exactly as declared, not recased to fit mid-sentence, because the
        # promise this whole projector makes is that a sentence here is a
        # sentence the chapter actually wrote.
        sentences = ["**#{command.hecks_name}**#{command.goal ? " — #{command.goal}." : '.'}"]
        sentences << "Issued by #{a_or_an(command.role)} #{command.role}." if command.role
        # `acts_on.nil?`, NOT `creates?` — `creates?` answers true for every
        # verb an ENTITY declares (it never references itself; see
        # `Command#acts_on`'s own comment), so reading it directly here would
        # tell an SME that `LedgerEntry.Amend` brings a new ledger entry into
        # being, which is exactly backwards.
        sentences << "This is how a new #{holder.hecks_name} comes into being." if command.acts_on.nil?

        arguments = command.attributes.reject(&:reference?)
        sentences << "It takes #{to_sentence_list(arguments.map { |a| Forms::Humanize.label(a.name.to_s).downcase })}." unless arguments.empty?

        refs = command.attributes.select(&:reference?)
        sentences << "It's aimed at one existing #{to_sentence_list(refs.map { |r| r.type.target_name })}, by id." unless refs.empty?

        conditions = conditions_of(command, holder)
        sentences << "It only goes through if #{conditions.join('; ')}." unless conditions.empty?

        guarantees = command.ensures.map(&:description)
        sentences << "When it succeeds: #{guarantees.join('; ')}." unless guarantees.empty?

        sentences << "It records `#{command.emits.join('`, `')}` as a fact." unless command.emits.empty?

        sentences.join(" ")
      end

      # EVERY REQUIRED CONDITION, STATED AS SOMETHING THAT MUST BE TRUE —
      # the same three sources `DocsProjector#refusals_of` reads (the
      # lifecycle edge, a reference's existence, and the command's own
      # `given`s), but kept positive rather than phrased as a refusal
      # reason. "Refused unless not X" is a sentence a reader has to
      # invert in their head; "only goes through if X" is not.
      def conditions_of(command, holder)
        conditions = []

        lifecycle = holder.lifecycle
        if lifecycle
          froms = lifecycle.transitions.filter_map { |name, transition|
            Array(transition.from) if name.to_s == command.hecks_name
          }.flatten.uniq
          conditions << "its `#{lifecycle.field}` is currently #{to_sentence_list(froms.map { |f| "`#{f}`" }, conj: 'or')}" unless froms.empty?
        end

        conditions + command.givens.map(&:description)
      end

      # ── the reads ─────────────────────────────────────────────────────

      def queries_narrative(queries, holder_name, depth)
        return nil if queries.empty?

        header = DocsProjector.h(depth, "Questions you can ask about #{a_or_an(holder_name)} #{holder_name}")
        lines = queries.map do |query|
          shape   = query.to_h
          takes   = Array(shape[:attributes]).map { |a| Forms::Humanize.label(a[:name].to_s).downcase }
          # `w[:value]` ALREADY WEARS ITS OWN QUOTES OR COLON — it is a
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

      def op_words(op)
        { eq: "is", lt: "under", lte: "at most", gt: "over", gte: "at least" }[op.to_s.to_sym] || op.to_s
      end

      # ── what happens on its own ───────────────────────────────────────

      def reactions_narrative(bluebook, depth)
        return nil if bluebook.policies.empty? && bluebook.process_managers.empty?

        parts = [DocsProjector.h(depth, "Reactions")]
        bluebook.policies.each do |policy|
          elsewhere = policy.target_domain ? " in #{policy.target_domain}" : ""
          parts << "Whenever `#{policy.on_event}` happens, `#{policy.trigger_command}` fires on its own#{elsewhere} — nobody has to ask for it."
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

      def to_sentence_list(items, conj: "and")
        case items.size
        when 0 then ""
        when 1 then items[0].to_s
        when 2 then "#{items[0]} #{conj} #{items[1]}"
        else "#{items[0..-2].join(', ')}, #{conj} #{items[-1]}"
        end
      end

      def a_or_an(word)
        %w[a e i o u].include?(word.to_s[0].to_s.downcase) ? "an" : "a"
      end
    end
  end
end
