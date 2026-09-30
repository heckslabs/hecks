# frozen_string_literal: true

require_relative "../tools"

module Hecks
  module Tools
    # Removes a command's `attribute :field, Type` line when it only repeats what an `append:`
    # target element already declares (see `CommandBuilder#resolve_append_fields!`). The
    # edit/reboot/diff-or-revert machinery lives in `Hecks::Codemod`.
    #
    #   hecks drop_implicit_append_fields [--dry-run]
    module DropImplicitAppendFields
      # One attribute a command repeats.
      Candidate = Struct.new(:command_name, :field, :type, keyword_init: true)

      module_function

      # Runs the codemod over every example domain and prints what it found.
      #
      # @param argv [Array<String>] `--dry-run` to restore every file after the rewrite is checked
      # @param root [String] the checkout (unused: the examples come from `Codemod`)
      # @return [Integer] 0
      def main(argv, root: Tools::ROOT)
        _ = root
        require "hecks"
        require "hecks/codemod"
        dry_run = argv.include?("--dry-run")

        runner = Hecks::Codemod::Runner.new(find_candidates: method(:find_candidates),
                                            apply_candidate: method(:apply_candidate),
                                            label:           ->(c) { "#{c.command_name}##{c.field} (#{c.type})" })
        results = runner.run(dry_run: dry_run)
        runner.report(results, dry_run: dry_run)
        0
      end

      # @param candidate [Candidate] the attribute a command declares
      # @param owner_attr [Object, nil] the same attribute on the element the command appends to
      # @return [Boolean] whether the two declare the same thing
      def identical_attribute?(candidate, owner_attr)
        return false unless owner_attr

        %i[type pattern optional? admits].all? { |m| candidate.public_send(m) == owner_attr.public_send(m) }
      end

      # Replays `CommandBuilder#resolve_append_fields!`'s lookup against the booted IR.
      #
      # @param registry [Object] the booted bluebooks
      # @return [Array<Candidate>] the attributes that can be dropped
      def find_candidates(registry)
        found = []
        Hecks::Codemod.each_command(registry) do |construct, command|
          command.mutations.select { |m| m.op == :append }.each do |mutation|
            element = Hecks::Codemod.element_construct_for(construct, mutation.target)
            next unless element

            mutation.source.each do |field, value|
              next unless value.is_a?(Symbol) && value.to_s == field.to_s

              local = command.attributes.find { |attr| attr.name.to_s == field.to_s }
              next unless local

              owner_attr = Hecks::Codemod.owner_attribute(element, field)
              next unless identical_attribute?(local, owner_attr)

              found << Candidate.new(command_name: command.hecks_name, field: field.to_s, type: local.type)
            end
          end
        end
        found
      end

      # @param text [String] a bluebook's source
      # @param candidate [Candidate] the attribute to drop
      # @return [Array(String, Boolean)] `[new_text, true]` on a single clean match, `[text, false]`
      #   when ambiguous or absent
      def apply_candidate(text, candidate)
        window_start = text.index(/^\s*command\s+"#{Regexp.escape(candidate.command_name)}"/)
        return [text, false] unless window_start

        window_end = text.index(/^\s*emits\s/, window_start)
        return [text, false] unless window_end

        before = text[0...window_start]
        window = text[window_start...window_end]
        after = text[window_end..]

        pattern = /^[ \t]*attribute\s+:#{Regexp.escape(candidate.field)}\s*,[^\n]*\n/
        return [text, false] unless window.scan(pattern).size == 1

        [before + window.sub(pattern, "") + after, true]
      end
    end
  end
end
