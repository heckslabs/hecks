require_relative "../runtime/errors"

module Hecksagain
  module Facade
    # THE CLI DOOR — WHERE Facade MEETS A CALLER HOLDING FLAT STRINGS.
    #
    # `JsonDoor` beside this one translates for a caller holding parsed JSON:
    # String keys, already-nested objects, real Integers. A command line has
    # neither of those. It has `sequence.value=99` — one flat string, with the
    # nesting spelled as a path and the type not spelled at all.
    #
    # So this does the two things that turns into: rebuild the nesting, and
    # give every leaf the type the chapter declared for it.
    #
    # THE TYPE COMES FROM THE PROJECTION, NEVER FROM THE VALUE. A door that
    # guessed — "99 looks like a number" — would send the Integer 99 for a
    # version string of "99", and be wrong in a way nothing downstream could
    # detect, because both are perfectly good arguments. `Projector::CliProjector`
    # already read the declared field type out of the value object; this only
    # applies it.
    module CliDoor
      module_function

      # `["reference.value=BUG#1", "sequence.value=99"]` against a projected
      # verb spec -> `{ reference: { value: "BUG#1" }, sequence: { value: 99 } }`
      def arguments(spec, pairs)
        # Legacy options are accepted but not printed in help. This lets an
        # existing id=... aggregate invocation cross the new receiver boundary
        # while the projected surface teaches to=... exclusively.
        options = (spec[:arguments] + Array(spec[:legacy_arguments])).to_h do |argument|
          [argument[:path], argument]
        end

        pairs.each_with_object({}) do |pair, args|
          path, value = split(pair)
          argument    = options[path] || options[expand(path, options)] ||
                        raise(Runtime::NotFound, unknown(path, options.keys))

          full = options.key?(path) ? path : expand(path, options)
          next append(args, full.split("."), cast(value, argument[:type])) if argument[:list]

          bury(args, full.split("."), cast(value, argument[:type]))
        end
      end

      def split(pair)
        name, value = pair.split("=", 2)
        raise Runtime::NotFound, "#{pair.inspect} is not name=value" if value.nil?

        [name, value]
      end

      # THE SHORT FORM, FOR THE COMMON CASE. Almost every value object in this
      # corpus has exactly one field, so `reference=BUG#1` is unambiguous and
      # is what anybody types. Expanded only when precisely one option starts
      # with that prefix — two would be a guess, and a guess about which field
      # a caller meant is worse than asking them to say.
      def expand(path, options)
        candidates = options.keys.select { |key| key.start_with?("#{path}.") }
        candidates.length == 1 ? candidates.first : path
      end

      def cast(value, type)
        case type
        when "Integer" then Integer(value)
        when "Float"   then Float(value)
        when "Boolean" then %w[true yes 1].include?(value.downcase)
        else value
        end
      rescue ArgumentError
        raise Runtime::TypeMismatch, "#{value.inspect} is not #{type} — the chapter declares this field as #{type}"
      end

      # A LIST GROWS RATHER THAN OVERWRITES, and getting this wrong is silent.
      #
      # `tags.value=framework tags.value=model-checker` used to reach `bury`
      # twice and store the second one alone — no refusal, no warning, one tag
      # simply gone. That is the failure the interview named first: not the
      # loud kind, the kind where a value is forgotten and the caller has no
      # way to notice.
      #
      # A LIST OF ONE IS STILL A LIST. `tags.value=flaky` produces
      # `[{ value: "flaky" }]`, not `{ value: "flaky" }`, because the chapter
      # declared a collection and a caller who sent one element did not
      # thereby declare a different shape. The old behaviour handed a bare
      # object to a `list_of` attribute, and everything downstream that walks
      # it — a query's `contains`, a projection, the Postgres adapter's own
      # array handling — is entitled to assume it can iterate.
      #
      # MULTI-FIELD ELEMENTS ARE NOT SUPPORTED HERE, deliberately. A flat
      # command line has no way to say which `a.x=` goes with which `a.y=`,
      # and inventing an index syntax would be a language nobody asked for.
      # Every list in this corpus is a list of single-field value objects; a
      # richer one is a job for `JsonDoor`, which has real nesting.
      def append(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        holder = branches[0..-2].reduce(hash) { |node, key| node[key] ||= {} }
        list   = holder[branches.last] ||= []

        list << { leaf => value }
        hash
      end

      def bury(hash, path, value)
        *branches, leaf = path.map(&:to_sym)
        target = branches.reduce(hash) { |node, key| node[key] ||= {} }
        target[leaf] = value
        hash
      end

      def unknown(path, known)
        "no argument #{path.inspect} — this verb takes #{known.sort.join(', ')}"
      end
    end
  end
end
