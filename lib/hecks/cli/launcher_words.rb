module Hecks
  module CLI
    # The launcher's `name=value` spellings of a subcommand's arguments, rewritten into the words
    # the subcommand reads. `CLI` extends it.
    module LauncherWords
      # The launcher's flags that mean the same for every subcommand here: `--wait` (a subcommand
      # exits with its own verdict, so waiting changes nothing) and `--confirm` (nothing here asks
      # for one). Each may carry a Boolean word, as at the launcher.
      GENERIC_FLAGS = ["--wait", "--confirm"].freeze

      # A launcher word: `name=value`, where the name has no path characters.
      NAME_VALUE = /\A[A-Za-z_][\w-]*=/

      # The launcher's `name=value` spellings of a subcommand's positional arguments.
      #
      # `slots` lists, in positional order, the names that fill each place (`domain` before
      # `aggregate`); `many` lets the first slot repeat and take a comma list; `exists` makes
      # the first slot's values paths that must exist; `flags` and `options` are `--name`
      # switches and `--name value` pairs; `ignored` names a launcher argument this form has no
      # use for. A subcommand absent here (`run`, whose pairs are the verb's own, `mcp`, and
      # `project_diagrams`, whose launcher form answers instead of writing) keeps its words.
      LAUNCHER_FORMS = {
        "docs"        => { slots: [%w[domain], %w[aggregate]], exists: true },
        "narrate"     => { slots: [%w[domain], %w[aggregate]], exists: true },
        "ir"          => { slots: [%w[domain]], flags: %w[translations meta], exists: true },
        "stores"      => { slots: [%w[domain]], exists: true },
        "model_check" => { slots: [%w[domains domain]], many: true, flags: %w[strict],
                           options: %w[profile], ignored: %w[run] },
        "smoke_test"  => { slots: [%w[subject domain]], ignored: %w[run] },
        "project_cli" => { slots: [%w[domain]], many: true }
      }.freeze

      # Subcommands whose words are their own: `run`'s pairs and `mcp`'s flags are not the
      # launcher's.
      UNTOUCHED = %w[run mcp].freeze

      # Subcommands whose `name=value` form is the launcher's own question, which answers
      # differently from the positional form: `project_diagrams` writes files, the question prints.
      LAUNCHER_ANSWERS = ["project_diagrams"].freeze

      # Whether a command line is the launcher's own form of a subcommand that answers differently
      # from its positional form, so the executable leaves it to the launcher.
      #
      # @param argv [Array<String>] the command line, subcommand first
      # @return [Boolean]
      def launcher_form?(argv)
        LAUNCHER_ANSWERS.include?(argv.first) && argv.drop(1).any? { |word| word.match?(NAME_VALUE) }
      end

      # Rewrites the launcher's spellings into the subcommand's own: drops the generic flags and
      # turns `name=value` words into the positionals and flags the subcommand reads.
      #
      # @param name [String] a key of `COMMANDS`
      # @param rest [Array<String>] the words after the subcommand
      # @return [Array(Array<String>, String)] the words to run with, and a refusal (nil when
      #   there is none)
      def launcher_words(name, rest)
        return [rest, nil] if UNTOUCHED.include?(name)

        require_relative "../adapters/driving/cli"
        words = strip_generic(rest)
        form  = LAUNCHER_FORMS[name]
        return [words, nil] unless form && words.any? { |word| word.match?(NAME_VALUE) }

        bind_launcher_words(form, words)
      rescue Runtime::TypeMismatch => e
        [nil, e.message]
      end

      # Binds the `name=value` words of `words` into the form's slots and flags.
      # @api private
      #
      # @param form [Hash] an entry of `LAUNCHER_FORMS`
      # @param words [Array<String>] the words after the subcommand, generic flags removed
      # @return [Array(Array<String>, String)] the words to run with, and a refusal (nil when
      #   there is none)
      def bind_launcher_words(form, words)
        slots, extra, refusal = bind_named_words(form, words)
        return [nil, refusal] if refusal

        missing = slots.first.find { |path| !File.exist?(path) } if form[:exists]
        return [nil, "no such domain #{missing.inspect}"] if missing

        [words.grep_v(NAME_VALUE) + extra + slots.flatten, nil]
      end

      # Sorts the `name=value` words of `words` into the form's positional slots and its flags.
      # @api private
      #
      # @param form [Hash] an entry of `LAUNCHER_FORMS`
      # @param words [Array<String>] the words after the subcommand, generic flags removed
      # @return [Array(Array<Array<String>>, Array<String>, String)] the slot contents, the extra
      #   flag words, and a refusal (nil when there is none)
      def bind_named_words(form, words)
        slots = Array.new(form[:slots].length) { [] }
        extra = []
        words.grep(NAME_VALUE).each do |word|
          refusal = bind_word(form, word, slots, extra)
          return [nil, nil, refusal] if refusal
        end
        [slots, extra, nil]
      end

      # Files one `name=value` word into its slot, or as a flag or option.
      # @api private
      #
      # @return [String, nil] a refusal when the form takes no such argument
      def bind_word(form, word, slots, extra)
        key, value = word.split("=", 2)
        key  = key.tr("-", "_")
        slot = form[:slots].index { |names| names.include?(key) }
        return bind_flag_or_option(form, key, value, extra) unless slot

        slots[slot].concat(form[:many] ? value.split(",") : [value])
        nil
      end

      # Appends the flag or option word for one `name=value` into `extra`.
      # @api private
      #
      # @return [String, nil] a refusal when the form takes no such argument
      def bind_flag_or_option(form, key, value, extra)
        return add_flag(key, value, extra) if listed?(form, :flags, key)
        return add_option(key, value, extra) if listed?(form, :options, key)
        return if listed?(form, :ignored, key)

        known = form[:slots].flatten + Array(form[:flags]) + Array(form[:options])
        "no argument #{key.inspect} — this verb takes #{known.sort.join(", ")}"
      end

      # @api private
      def listed?(form, kind, key) = Array(form[kind]).include?(key)

      # @api private
      def add_flag(key, value, extra)
        extra << "--#{key.tr("_", "-")}" if Adapters::Driving::Cli.boolean(value)
        nil
      end

      # @api private
      def add_option(key, value, extra)
        extra.push("--#{key}", value)
        nil
      end

      # Takes `--wait` and `--confirm`, each with an optional Boolean word, out of `words`.
      # @api private
      def strip_generic(words)
        queue = words.dup
        kept  = []
        until queue.empty?
          word = queue.shift
          flag, value = word.split("=", 2)
          next kept << word unless GENERIC_FLAGS.include?(flag)

          Adapters::Driving::Cli.boolean(value || generic_value(queue))
        end
        kept
      end

      # The Boolean word that follows a generic flag, or "true" when none does.
      # @api private
      def generic_value(queue)
        Adapters::Driving::Cli::BOOLEAN_WORDS.key?(queue.first.to_s.downcase) ? queue.shift : "true"
      end
    end
  end
end
