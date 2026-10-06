module Hecks
  module Projector
    module NarrateProjector
      # The prose for the verbs of an aggregate or entity: one paragraph per command, each
      # sentence quoting a declared `goal`, `role`, argument, `given` or `ensure`.
      module Commands
        module_function

        # The "What can happen to ..." section for `holder`, or `nil` when it has no commands.
        def verbs_narrative(holder, depth)
          return nil if holder.commands.empty?

          name   = holder.hecks_name
          header = DocsProjector.h(depth, "What can happen to #{NarrateProjector.a_or_an(name)} #{name}")
          body   = holder.commands.map { |command| command_paragraph(command, holder) }.join("\n\n")
          "#{header}\n\n#{body}"
        end

        # Each sentence states one independent fact, so nil-or-string plus `compact.join` suffices.
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

        # The goal is quoted exactly as declared, never recased to fit mid-sentence.
        def command_headline_sentence(command)
          "**#{command.hecks_name}**#{command.goal ? " — #{command.goal}." : "."}"
        end

        def command_role_sentence(command)
          return nil unless command.role

          "Issued by #{NarrateProjector.a_or_an(command.role)} #{command.role}."
        end

        # `acts_on.nil?`, not `creates?`: `creates?` is true for every entity verb, which would
        # wrongly say `LedgerEntry.Amend` creates a new ledger entry.
        def command_creation_sentence(command, holder)
          return nil unless command.acts_on.nil?

          "This is how a new #{holder.hecks_name} comes into being."
        end

        def command_arguments_sentence(command)
          arguments = command.attributes.reject(&:reference?)
          return nil if arguments.empty?

          labels = arguments.map { |a| Forms::Humanize.label(a.name.to_s).downcase }
          "It takes #{NarrateProjector.to_sentence_list(labels)}."
        end

        def command_references_sentence(command)
          refs = command.attributes.select(&:reference?)
          return nil if refs.empty?

          "It's aimed at one existing #{NarrateProjector.to_sentence_list(refs.map { |r| r.type.target_name })}, by id."
        end

        def command_conditions_sentence(command, holder)
          conditions = conditions_of(command, holder)
          return nil if conditions.empty?

          "It only goes through if #{conditions.join("; ")}."
        end

        def command_guarantees_sentence(command)
          guarantees = command.ensures.map(&:description)
          return nil if guarantees.empty?

          "When it succeeds: #{guarantees.join("; ")}."
        end

        def command_emits_sentence(command)
          return nil if command.emits.empty?

          "It records `#{command.emits.join("`, `")}` as a fact."
        end

        # Required conditions stated positively ("only goes through if X"), from the lifecycle
        # edge and the command's `given`s.
        def conditions_of(command, holder)
          lifecycle_conditions(command, holder.lifecycle) + command.givens.map(&:description)
        end

        # The condition that the record is in a state the lifecycle allows the command from.
        def lifecycle_conditions(command, lifecycle)
          return [] unless lifecycle

          froms = lifecycle.transitions.filter_map do |name, transition|
            Array(transition.from) if name.to_s == command.hecks_name
          end.flatten.uniq
          return [] if froms.empty?

          states = NarrateProjector.to_sentence_list(froms.map { |f| "`#{f}`" }, conj: "or")
          ["its `#{lifecycle.field}` is currently #{states}"]
        end
      end
    end
  end
end
