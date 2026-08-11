require "hecksagain"

module Hecksagain
  module Interview
    # A verb's own shape, as a ready-to-fill --arg template — pulled out of
    # `bin/interview`'s `render_shape` so both the real CLI and this
    # library's own tests can call it directly, without paying for a fresh
    # OS process (and a fresh `MetaValidator.grammar_registry` build) per
    # verb. A PURE grammar lookup — reads the same real IR objects
    # `bin/ir --meta` exports, never a session's own store, never a chapter
    # argument, never `--at`.
    module Shape
      UnknownVerb = Class.new(StandardError)

      # A REAL CONSTRAINT, NOT A GUESS — traced through
      # `read_model_interpreter.rb`'s own `args.fetch(model.reference_name)`
      # (no default) before building this. A read model joins several
      # aggregates around ONE root, queried by that root's own id — there is
      # no "give me every row" mode, no matter how the `where`/`order_by`
      # options declared on it are shaped; those only ever scope the "many"
      # side WITHIN one root's own projection.
      READ_MODEL_NOTE = "  A READ MODEL ANSWERS ONE ROOT AT A TIME, not \"all\" — " \
                         "call it once per id (from the root aggregate's own .all), never in bulk."

      # THE FULL CLOSED-SET SEQUENCE, discovered the hard way mid-interview:
      # `Member.Declare` alone renders an EMPTY `value_object` block — no
      # refusal at propose time, only a crash once the domain actually
      # loads. All five verbs below print the note, so whichever one you
      # reach for first is the one that tells you what else it needs.
      CLOSED_SET_VERBS = %w[
        Bluebook::ValueObject.Declare Bluebook::ValueObject.Field
        Bluebook::Member.Declare Bluebook::Member.Pair Bluebook::ValueObject.Close
      ].freeze

      NO_PAINT = ->(text, _colour) { text }

      module_function

      # `paint` defaults to plain text so this stays a pure function of the
      # verb; `bin/interview` passes its own colour-aware `Paint.call` so
      # real CLI output is unchanged.
      def render(verb_text, paint: NO_PAINT)
        chapter_name, aggregate_name, command_name =
          verb_text.match(/\A([A-Za-z]+)::([A-Za-z]+)\.([A-Za-z]+)\z/)&.captures
        raise UnknownVerb, "#{verb_text.inspect} isn't fully qualified — Chapter::Aggregate.Command" unless chapter_name

        registry = Hecksagain::Bluebook::MetaValidator.grammar_registry
        chapter = registry.bluebook(chapter_name) or
          raise UnknownVerb, "no chapter #{chapter_name.inspect} in the language"
        aggregate = chapter.aggregate(aggregate_name) or
          raise UnknownVerb, "#{chapter_name} declares no aggregate #{aggregate_name.inspect}"
        command = aggregate.command(command_name) or
          raise UnknownVerb, "#{aggregate_name} declares no command #{command_name.inspect}"

        lines = ["#{paint.call(verb_text, :blue)}  —  #{command.goal}"]
        lines << addressing_line(chapter, command.references, paint) if command.references
        lines << closed_set_note(paint) if CLOSED_SET_VERBS.include?(verb_text)
        lines << READ_MODEL_NOTE if verb_text == "Bluebook::ReadModel.Declare"
        command.attributes.each { |attribute| lines << shape_line(chapter, aggregate, attribute) }
        lines.join("\n")
      end

      # WHAT `--arg "id::..."` HAS TO SPELL, when a command ACTS ON an
      # existing record rather than creating one — `command.references`
      # names the category (`"ValueObject"`, `"Aggregate"`, ...); every
      # category's own `id` is `Naming.identity(identity_paths)`, a
      # colon-join of its declared identity parts IN ORDER.
      def addressing_line(chapter, references, paint)
        target = chapter.aggregate(references)
        return "  addresses #{references} — identity unknown (not declared in #{chapter.name})" unless target

        parts = target.identity_paths.empty? ? ["id"] : target.identity_paths
        example = parts.map { |path| "<#{path.to_s.split('.').first}>" }.join(":")
        "  addresses #{paint.call(references, :yellow)} — id = #{parts.join(' + ":" + ')}  (e.g. #{example})"
      end

      def closed_set_note(paint)
        paint.call("  A CLOSED SET NEEDS ALL FIVE, not just this one:", :dim) + "\n" +
          paint.call("    ValueObject.Declare  — the value object's own root\n" \
                      "    ValueObject.Field    — its field (almost always name: value, type: String)\n" \
                      "    Member.Declare       — one call per admitted row, each with its own position (0, 1, 2, ...)\n" \
                      "    Member.Pair          — one call per row: key: value, value: <the actual text>\n" \
                      "    ValueObject.Close    — rows: <count>, the count of Member rows above", :dim)
      end

      def shape_line(chapter, aggregate, attribute)
        required = attribute.optional? ? "optional" : "required"
        return "  #{attribute.name.to_s.ljust(14)} reference -> #{attribute.type.target_name.ljust(20)} #{required}   " \
               "--arg \"#{attribute.name}::<id>\"" if attribute.reference?

        value_object = aggregate.value_object(attribute.type) ||
                        chapter.aggregates.filter_map { |a| a.value_object(attribute.type) }.first
        return "  #{attribute.name.to_s.ljust(14)} #{attribute.type.to_s.ljust(20)} #{required}   " \
               "(unknown shape — not declared anywhere in #{chapter.name}; try field 'value')" unless value_object

        value_object.attributes.map do |field|
          "  #{attribute.name.to_s.ljust(14)} #{attribute.type}{#{field.name}: #{field.type}}".ljust(48) +
            " #{required}   --arg \"#{attribute.name}:#{field.name}:<#{field.type}>\""
        end.join("\n")
      end
    end
  end
end
