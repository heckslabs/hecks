# frozen_string_literal: true

require_relative "../tools"

module Hecks
  module Tools
    # Walks a bluebook language change (syntax row, builder, golden) through its lifecycle:
    # `status`, `propose`, `admit`, `deprecate`, `retire` and `rename` a word, and the
    # `argument-*` forms of the same for a keyword's arguments (see `USAGE`).
    #
    #   bin/evolve propose <word> --context Aggregate  a row enters, proposed
    #   bin/evolve admit   <word> --context Aggregate  proposed -> admitted
    #   bin/evolve rename  <word> --context X --to new
    #
    # Mutating commands regenerate the golden and run the gates; a failing gate restores every file.
    module EvolveRun
      # The specs a change must keep green.
      GATES = %w[
        spec/syntax_conformance_spec.rb
        spec/syntax_lifecycle_spec.rb
        spec/ir_golden_spec.rb
      ].freeze

      # Words that move a word to a status.
      WORD_STATUS = { "admit" => "admitted", "deprecate" => "deprecated", "retire" => "retired" }.freeze

      # Words that move a keyword's argument to a status.
      ARGUMENT_STATUS = { "argument-admit" => "admitted", "argument-deprecate" => "deprecated",
                          "argument-retire" => "retired" }.freeze

      USAGE = "usage: bin/evolve status|propose|admit|deprecate|retire <word> --context <Context> " \
              "[--body none|keywords|source|rows] [--inner X] [--opens X] [--fills x]\n   " \
              "or: bin/evolve argument-propose|argument-admit|argument-deprecate|argument-retire " \
              "<keyword> --context <Context> [--kind K] [--at N] [--named NAME] [--required true|false] " \
              "[--fills F]"

      module_function

      # Runs one lifecycle command.
      #
      # @param argv [Array<String>] the command, its word or keyword, then its flags
      # @param root [String] the checkout whose syntax tables and golden are edited
      # @return [Integer] 0, or 1 when a gate refuses and the files are restored
      # @raise [SystemExit] with the reason when an argument is missing
      def main(argv, root: Tools::ROOT)
        require "hecks/grammar/evolve"
        args = argv.dup
        command = args.shift
        evolve = Hecks::Grammar::Evolve
        ok =
          case command
          when "status" then status(evolve)
          when "propose" then propose(args, evolve, root)
          when *WORD_STATUS.keys then set_status(command, args, evolve, root)
          when "rename" then rename(args, evolve, root)
          when "argument-propose" then propose_argument(args, evolve, root)
          when *ARGUMENT_STATUS.keys then set_argument_status(command, args, evolve, root)
          else abort USAGE
          end
        ok == false ? 1 : 0
      end

      # Rewrites spec/golden/ir/Bluebook.json by running its spec with `GOLDEN=rewrite`.
      #
      # @param root [String] the checkout
      # @return [Boolean, nil] whether the spec ran green
      def regenerate!(root)
        system({ "GOLDEN" => "rewrite" },
               "bundle", "exec", "rspec", "spec/ir_golden_spec.rb",
               chdir: root, out: File::NULL, err: File::NULL)
      end

      # Runs the syntax conformance, syntax lifecycle and golden IR specs.
      #
      # @param root [String] the checkout
      # @return [Boolean, nil] whether they passed
      def gates_pass?(root)
        system("bundle", "exec", "rspec", *GATES, chdir: root)
      end

      # Runs one grammar edit inside the snapshot/regenerate/gate sequence, restoring every
      # snapshot if the block raises or a gate fails.
      #
      # @param word [String] what the edit is about, for the report
      # @param context [String] the aggregate the word belongs to
      # @param evolve [Module] `Hecks::Grammar::Evolve`
      # @param root [String] the checkout
      # @return [Boolean] true if the block ran and the gates held
      def guarded(word, context, evolve, root, &)
        paths = evolve.syntax_paths + [File.join(root, "spec/golden/ir/Bluebook.json")]
        snapshots = paths.to_h { |path| [path, File.read(path)] }
        evolve.restore_on_raise(paths, &)
        regenerate!(root)
        if gates_pass?(root)
          puts "\n#{context}.#{word} — the gates hold. Regenerated projections and the golden are in the tree."
          true
        else
          snapshots.each { |path, content| File.write(path, content) }
          puts "\nRESTORED — the gates refused, and the failures above are the checklist. " \
               "Nothing was changed."
          false
        end
      rescue StandardError => e
        # `restore_on_raise` has already restored the files; this only reports.
        puts "\nRESTORED — #{e.message} Nothing was changed."
        false
      end

      # @return [true]
      def status(evolve) # rubocop:disable Naming/PredicateMethod
        rows = evolve.keyword_rows
        moving = rows.reject { |row| row[:status] == "admitted" }
        renamed = rows.reject { |row| row[:was].to_s.empty? }
        puts "#{rows.size} keyword rows; #{moving.size} not simply admitted; #{renamed.size} renamed"
        moving.each { |row| puts "  #{row[:status].ljust(10)} #{row[:context]}.#{row[:word]}" }
        renamed.each { |row| puts "  renamed    #{row[:context]}.#{row[:word]} (was #{row[:was]})" }
        true
      end

      # @return [Boolean] whether the gates held
      def propose(args, evolve, root)
        word = args.shift or abort "propose what word?"
        context = evolve.option(args, "context") or abort "--context is required — a word is a word somewhere"
        ok = guarded(word, context, evolve, root) do
          evolve.propose(word: word, context: context,
                         body: evolve.option(args, "body", "none"), inner: evolve.option(args, "inner", ""),
                         opens: evolve.option(args, "opens", ""), fills: evolve.option(args, "fills", ""))
        end
        if ok
          puts "Proposed. It reaches no projection until admitted. Before `bin/evolve admit`:"
          puts "  1. teach the #{context} builder the word (and its spec/dsl_spec example)"
        end
        ok
      end

      # @return [Boolean] whether the gates held
      def set_status(command, args, evolve, root)
        word = args.shift or abort "#{command} what word?"
        context = evolve.option(args, "context") or abort "--context is required"
        guarded(word, context, evolve, root) do
          evolve.set_status(word: word, context: context, to: WORD_STATUS.fetch(command))
        end
      end

      # @return [Boolean] whether the gates held
      def rename(args, evolve, root)
        word = args.shift or abort "rename what word?"
        context = evolve.option(args, "context") or abort "--context is required"
        to = evolve.option(args, "to") or abort "--to is required — a rename goes somewhere"
        ok = guarded(word, context, evolve, root) { evolve.rename(word: word, context: context, to: to) }
        if ok
          puts "Renamed. The old spelling keeps parsing — that is the point. Before this holds:"
          puts "  1. alias the new word to the old in the #{context} builder (alias_method :#{to}, :#{word})"
          puts "  2. add the identical-IR example to spec/dsl_spec.rb"
        end
        ok
      end

      # @return [Boolean] whether the gates held
      def propose_argument(args, evolve, root)
        keyword = args.shift or abort "argument-propose which keyword's argument?"
        context = evolve.option(args, "context") or abort "--context is required"
        kind = evolve.option(args, "kind") or abort "--kind is required — text|symbol|number|flag|literal|constant|pairs|list"
        ok = guarded("#{keyword} argument", context, evolve, root) do
          evolve.propose_argument(keyword: keyword, context: context, kind: kind,
                                  required: evolve.option(args, "required", "false"),
                                  at: evolve.option(args, "at", ""), named: evolve.option(args, "named", ""),
                                  fills: evolve.option(args, "fills", ""),
                                  pairs_shape: evolve.option(args, "pairs-shape"))
        end
        if ok
          puts "Proposed. It reaches no projection until admitted. Before `bin/evolve argument-admit`:"
          puts "  1. teach the #{context} builder's #{keyword} method the argument"
        end
        ok
      end

      # @return [Boolean] whether the gates held
      def set_argument_status(command, args, evolve, root)
        keyword = args.shift or abort "#{command} which keyword's argument?"
        context = evolve.option(args, "context") or abort "--context is required"
        guarded("#{keyword} argument", context, evolve, root) do
          evolve.set_argument_status(keyword: keyword, context: context, to: ARGUMENT_STATUS.fetch(command),
                                     at: evolve.option(args, "at", ""), named: evolve.option(args, "named", ""))
        end
      end
    end
  end
end
