require_relative "../../naming"

module Hecks
  module Projector
    module CliProjector
      # The spec hash of each command, port operation, query and report: what the runner parses
      # a call against and what `--help` describes.
      module CommandSpecs
        # The options that name the record a command acts on, before its own arguments.
        # `nil` (a creating command) takes none: there is no record yet.
        # Ports always pass `:aggregate`, since a port is declared on an aggregate.
        def receiver_options(receiver, aggregate, entity)
          case receiver
          when :entity then entity_receiver_options(aggregate, entity)
          when :aggregate
            [{ path: "to", type: "String", required: true,
               note: "id of the #{aggregate.hecks_name} to act on" }]
          else
            []
          end
        end

        # The two ids that name an entity inside its aggregate.
        def entity_receiver_options(aggregate, entity)
          [{ path: "to.aggregate", type: "String", required: true,
             note: "id of the #{aggregate.hecks_name} holding the #{entity.hecks_name}" },
           { path: "to.entity", type: "String", required: true,
             note: "id of the #{entity.hecks_name} to act on" }]
        end

        # The spec of one command of an aggregate or of one of its entities.
        def command_spec(bluebook, aggregate, entity, command)
          receiver = receiver_for(entity, command)

          { command: fqn(bluebook, aggregate, command, entity), kind: :command }
            .merge(command_facts(aggregate, command))
            .merge(receiver_facts(receiver))
            .merge(refusals: refusals(command, entity || aggregate), requirements: requirements(command),
                   arguments: command_arguments(receiver, aggregate, entity, command))
        end

        # Who a command acts on: its entity, its aggregate, or nobody (a creating command).
        def receiver_for(entity, command)
          return :entity if entity

          command.creates? ? nil : :aggregate
        end

        # What the command declares about itself, apart from its arguments.
        def command_facts(aggregate, command)
          { summary: command.goal, role: command.role, role_gated: !command.role.to_s.empty?,
            group: aggregate.hecks_name, internal: command.role.to_s == "System",
            creates: command.creates? }
        end

        # The receiver entries of a spec. `id=...` is still accepted for aggregate receivers but
        # hidden from help, which teaches only `to=...`.
        def receiver_facts(receiver)
          { receiver: receiver, legacy_receiver: (receiver == :aggregate ? :id : nil),
            legacy_arguments: receiver == :aggregate ? [{ path: "id", type: "String", required: true }] : [] }
        end

        # The receiver paths stay in the projected option list so the request is complete;
        # CommandRequest strips them before building `with:`.
        def command_arguments(receiver, aggregate, entity, command)
          holder = entity || aggregate
          receiver_options(receiver, aggregate, entity) +
            command.attributes.flat_map { |a| options_for(a, holder, aggregate) }
        end

        # A port operation reads as a command but reports as a boundary: it creates no
        # record, and an outbound failure is the other side's sentence, so `refusals` is empty.
        def port_spec(bluebook, aggregate, port, operation)
          arguments = receiver_options(:aggregate, aggregate, nil) +
                      operation.attributes.flat_map { |a| options_for(a, aggregate, aggregate) }

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

        # Who issues a port operation, in the direction it runs.
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

        # The conditions that refuse the command when they hold, in the chapter's own words: a
        # lifecycle state mismatch and a missing referenced record per `reference_to`.
        def refusals(command, holder)
          lifecycle_refusals(command, holder) +
            command.attributes.select(&:reference?).map { |r| "no #{r.type.target_name} has that #{r.name}" }
        end

        # The refusal for a lifecycle state the command does not run from, or none.
        def lifecycle_refusals(command, holder)
          lifecycle = holder.lifecycle
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
