# frozen_string_literal: true

require_relative "../tools"
require_relative "evolve_run/words"
require_relative "evolve_run/arguments"

module Hecks
  module Tools
    # Walks a bluebook language change (syntax row, builder, golden) through its lifecycle:
    # `status`, `propose`, `admit`, `deprecate`, `retire` and `rename` a word, and the
    # `argument-*` forms of the same for a keyword's arguments (see `USAGE`).
    #
    #   hecks evolve propose <word> --context Aggregate  a row enters, proposed
    #   hecks evolve admit   <word> --context Aggregate  proposed -> admitted
    #   hecks evolve rename  <word> --context X --to new
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

      USAGE = "usage: hecks evolve status|propose|admit|deprecate|retire <word> --context <Context> " \
              "[--body none|keywords|source|rows] [--inner X] [--opens X] [--fills x]\n   " \
              "or: hecks evolve argument-propose|argument-admit|argument-deprecate|argument-retire " \
              "<keyword> --context <Context> [--kind K] [--at N] [--named NAME] [--required true|false] " \
              "[--fills F]"

      extend Words
      extend Arguments

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
        ok = run_command(args.shift, args, Hecks::Grammar::Evolve, root)
        ok == false ? 1 : 0
      end

      # @return [Boolean, nil] whether the command's gates held
      def run_command(command, args, evolve, root)
        case command
        when "status" then status(evolve)
        when "propose" then propose(args, evolve, root)
        when *WORD_STATUS.keys then set_status(command, args, evolve, root)
        when "rename" then rename(args, evolve, root)
        when "argument-propose" then propose_argument(args, evolve, root)
        when *ARGUMENT_STATUS.keys then set_argument_status(command, args, evolve, root)
        else abort USAGE
        end
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
        edit_and_gate(word, context, evolve, root, &)
      rescue StandardError => e
        # `restore_on_raise` has already restored the files; this only reports.
        puts "\nRESTORED — #{e.message} Nothing was changed."
        false
      end

      # @return [Boolean] true if the block ran and the gates held; false after restoring the
      #   snapshots when a gate refused
      def edit_and_gate(word, context, evolve, root, &) # rubocop:disable Naming/PredicateMethod -- the edit's verdict
        paths = evolve.syntax_paths + [File.join(root, "spec/golden/ir/Bluebook.json")]
        snapshots = paths.to_h { |path| [path, File.read(path)] }
        evolve.restore_on_raise(paths, &)
        regenerate!(root)
        if gates_pass?(root)
          puts "\n#{context}.#{word} — the gates hold. Regenerated projections and the golden are in the tree."
          return true
        end
        restore(snapshots)
        false
      end

      # Puts every snapshot back after a gate refused.
      def restore(snapshots)
        snapshots.each { |path, content| File.write(path, content) }
        puts "\nRESTORED — the gates refused, and the failures above are the checklist. " \
             "Nothing was changed."
      end

      # @return [true]
      def status(evolve) # rubocop:disable Naming/PredicateMethod -- the command always succeeds
        rows = evolve.keyword_rows
        moving = rows.reject { |row| row[:status] == "admitted" }
        renamed = rows.reject { |row| row[:was].to_s.empty? }
        puts "#{rows.size} keyword rows; #{moving.size} not simply admitted; #{renamed.size} renamed"
        print_status_rows(moving, renamed)
        true
      end

      def print_status_rows(moving, renamed)
        moving.each { |row| puts "  #{row[:status].ljust(10)} #{row[:context]}.#{row[:word]}" }
        renamed.each { |row| puts "  renamed    #{row[:context]}.#{row[:word]} (was #{row[:was]})" }
      end
    end
  end
end
