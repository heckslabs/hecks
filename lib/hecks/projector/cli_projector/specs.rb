module Hecks
  module Projector
    module CliProjector
      # The spec of one command, port operation, report or query: what `--help` prints and what
      # the runner parses a call against.
      module Specs
        module_function

        # The command's language name, `Chapter::Aggregate[.Entity].Verb`, for help text.
        def fqn(bluebook, aggregate, command, entity = nil)
          [bluebook.name, "::", aggregate.hecks_name, ".",
           entity ? "#{entity.hecks_name}." : "", command.hecks_name].join
        end

        # The spec of a command declared on an aggregate or one of its entities.
        def command_spec(bluebook, aggregate, entity, command)
          receiver = command_receiver(entity, command)

          { command: fqn(bluebook, aggregate, command, entity), kind: :command,
            **role_fields(command),
            group: aggregate.hecks_name, internal: command.role.to_s == "System",
            creates: command.creates?,
            **receiver_fields(receiver),
            refusals: refusals(command, entity || aggregate), requirements: requirements(command),
            arguments: command_arguments(command, aggregate, entity, receiver) }
        end

        # What the command acts on: its entity, its aggregate, or nothing when it creates one.
        def command_receiver(entity, command)
          return :entity if entity

          command.creates? ? nil : :aggregate
        end

        # The summary and the role that issues the command, with whether the role gates it.
        def role_fields(command)
          { summary: command.goal, role: command.role, role_gated: !command.role.to_s.empty? }
        end

        # The receiver and the hidden `id=...` spelling still accepted for aggregate receivers.
        def receiver_fields(receiver)
          { receiver: receiver, legacy_receiver: (receiver == :aggregate ? :id : nil),
            legacy_arguments: receiver == :aggregate ? [{ path: "id", type: "String", required: true }] : [] }
        end

        # The receiver paths stay in the projected option list so the request is complete;
        # CommandRequest strips them before building `with:`. `id=...` is still accepted
        # for aggregate receivers but hidden from help, which teaches only `to=...`.
        def command_arguments(command, aggregate, entity, receiver)
          holder = entity || aggregate
          own = command.attributes.flat_map { |a| Arguments.options_for(a, holder, aggregate) }
          Arguments.receiver_options(receiver, aggregate, entity) + own
        end

        # A port operation reads as a command but reports as a boundary: it creates no
        # record, and an outbound failure is the other side's sentence, so `refusals` is empty.
        def port_spec(bluebook, aggregate, port, operation)
          arguments = Arguments.receiver_options(:aggregate, aggregate, nil) +
                      operation.attributes.flat_map { |a| Arguments.options_for(a, aggregate, aggregate) }

          { command: port_wire_name(bluebook, aggregate, port, operation),
            kind: :command, creates: false, receiver: :aggregate, refusals: [],
            # `role:` is help text only; port dispatch never reaches the role check,
            # so `role_gated` is always false here.
            role: port_role(aggregate, port, operation),
            role_gated: false, group: aggregate.hecks_name, internal: true,
            summary: port_summary(port, operation), arguments: arguments }
        end

        # `Dispatcher#dispatch` looks the head up as a port, so the wire name is
        # `Aggregate.Port.Operation`; the launcher name hides the port.
        def port_wire_name(bluebook, aggregate, port, operation)
          [fqn(bluebook, aggregate, operation).sub(/\.[^.]+\z/, ""), port.name, operation.hecks_name].join(".")
        end

        # Who speaks: the aggregate asking the port, or the port telling the aggregate.
        def port_role(aggregate, port, operation)
          if operation.outbound?
            "#{aggregate.hecks_name} asking #{port.name}"
          else
            "#{port.name} telling #{aggregate.hecks_name}"
          end
        end

        # Names both endings of a port operation, since `--help` is where a caller
        # learns that e.g. a spec run answers `SpecsCompleted` even when the suite is red.
        def port_summary(port, operation)
          return "#{port.name} reports it; emits #{operation.emits.join(", ")}" unless operation.outbound?

          "Ask #{port.name} — answers #{operation.answers}, refuses #{operation.refuses}"
        end

        # A rootless report takes nothing; a rooted one takes the id of the record it
        # is a view of, under the name the model gave that reference.
        def report_spec(bluebook, model)
          arguments =
            if model.reference_target
              [{ path: model.reference_name.to_s, type: "String", required: true,
                 note: "id of the #{model.reference_target} this is a view of" }]
            else
              []
            end

          { command: "#{bluebook.name}.#{model.hecks_name}", kind: :query,
            summary: model.description, arguments: arguments }
        end

        # The spec of a query declared on an aggregate or one of its entities.
        def query_spec(bluebook, aggregate, entity, query)
          { command: fqn(bluebook, aggregate, query, entity), kind: :query, group: aggregate.hecks_name,
            internal: entity.nil? && bookkeeping_query?(aggregate, query),
            summary: query.description, arguments: query_arguments(query, aggregate, entity),
            returns: query.returns }
        end

        # The options of the attributes a query declares.
        def query_arguments(query, aggregate, entity)
          Array(query.to_h[:attributes]).flat_map do |declared|
            attribute = query.attributes.find { |a| a.name.to_s == declared[:name].to_s }
            attribute ? Arguments.options_for(attribute, entity || aggregate, aggregate) : []
          end
        end

        # A question that only reads the aggregate's own records back: it returns no document and
        # filters on nothing but the record's identity ("how one request ended") or its lifecycle
        # status ("every request that was refused"). Each journaled run has such a pair, which a
        # person reads through `hecks <command> --wait` rather than asking for by name, so the help
        # sets them apart with the bookkeeping commands. A query that returns a document, or filters
        # on anything else, is a real question. Only an aggregate that journals its own runs (it has
        # system-role commands, the ones `internal` commands are made of) has such a pair: a
        # release's "every version that was shipped" is a question worth asking by name.
        def bookkeeping_query?(aggregate, query)
          return false if query.returns || query.wheres.empty?
          return false unless aggregate.commands.any? { |command| command.role.to_s == "System" }

          own = own_fields(aggregate)
          query.wheres.all? { |clause| own.include?(clause.field.to_s) }
        end

        # The fields that are the aggregate's identity or its lifecycle status.
        def own_fields(aggregate)
          Array(aggregate.identified_by).map(&:to_s) + [aggregate.lifecycle&.field.to_s]
        end

        # The conditions that refuse the command when they hold, in the chapter's own words: a
        # lifecycle state mismatch and a missing referenced record per `reference_to`.
        def refusals(command, holder)
          lifecycle_refusals(command, holder.lifecycle) +
            command.attributes.select(&:reference?).map { |r| "no #{r.type.target_name} has that #{r.name}" }
        end

        # The refusal for a command called from a state its lifecycle does not allow it from.
        def lifecycle_refusals(command, lifecycle)
          return [] unless lifecycle

          froms = lifecycle.transitions.filter_map do |name, transition|
            Array(transition.from) if name.to_s == command.hecks_name
          end.flatten.uniq
          froms.empty? ? [] : ["#{lifecycle.field} is not #{froms.join(" or ")}"]
        end

        # The conditions the command needs: each `given` states what must hold, so the command is
        # refused unless it does.
        def requirements(command) = command.givens.map(&:description)
      end
    end
  end
end
