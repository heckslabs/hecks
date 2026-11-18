# frozen_string_literal: true

require "json"
require "zlib"
require_relative "../../tools"
require_relative "violations"

module Hecks
  module Tools
    module ArgumentGateMatrix
      # Builds the candidate rows: for each command, one input per adjacent pair of live gates that
      # violates both.
      module Rows
        # One command's context while its rows are built.
        Candidate = Struct.new(:command, :aggregate, :verb, :kind, :random, :base) do
          # @return [Boolean] whether the command creates its aggregate, so no record is hydrated
          def creating?
            kind == "aggregate" && command.creates?
          end
        end

        def base_args(command, aggregate, random)
          command.attributes.to_h do |attribute|
            [attribute.name.to_s, Hecks::Fuzzing::ValueGenerator.value_for(attribute, aggregate, random: random, known_ids: {})]
          end
        rescue ArgumentError
          nil
        end

        def identity_args(construct, aggregate, random)
          Array(construct.identified_by).to_h do |path|
            head = path.to_s.split(".").first
            attribute = construct.attributes.find { |a| a.name.to_s == head }
            value = attribute && Hecks::Fuzzing::ValueGenerator.value_for(attribute, aggregate, random: random, known_ids: {})
            [head, value || "no-such-#{head}"]
          end
        rescue ArgumentError
          {}
        end

        def live_gates(command, kind)
          gates = ["refuse_unknown_arguments", *argument_gates(command)]
          gates << SETTLES.fetch(kind) unless kind == "aggregate" && command.creates?
          gates
        end

        # The gates after the unknown-argument one that this command can violate.
        def argument_gates(command)
          gates = []
          gates << "refuse_absent_arguments" if droppable(command).any?
          gates << "normalize_args" if corruptible(command).any?
          gates << "refuse_role_mismatch" unless command.role.to_s.empty?
          gates << "resolve_references" if command.attributes.any?(&:reference?)
          gates
        end

        # One row per adjacent live-gate pair the command can violate on both steps. Commands with
        # an envelope-keyword attribute never reach an argument gate, so they yield none.
        def rows_for(command, aggregate, verb, kind, random)
          return [] if command.attributes.any? { |a| Violations::ENVELOPE_KEYS.include?(a.name.to_s) }

          base = base_args(command, aggregate, random)
          return [] if base.nil?

          candidate = Candidate.new(command, aggregate, verb, kind, random, base)
          live_gates(command, kind).each_cons(2).filter_map { |earlier, later| pair_row(candidate, earlier, later) }
        end

        # The row violating `earlier` and `later` on one input, or nil when either cannot be.
        def pair_row(candidate, earlier, later)
          args = fresh_args(candidate)
          violates = [earlier, later].to_h { |step| [step, violation_detail(candidate, step, args)] }
          return if violates.value?(nil)

          { verb: candidate.verb, kind: candidate.kind, role: role_for(earlier, later), pair: [earlier, later],
            violates: violates, args: args }
        end

        # A copy of the valid base input, naming the record it acts on unless the command
        # creates one.
        def fresh_args(candidate)
          args = JSON.parse(JSON.generate(candidate.base))
          return args if candidate.creating?

          args.merge!(identity_args(candidate.aggregate, candidate.aggregate, candidate.random))
        end

        def violation_detail(candidate, step, args)
          violate!(step, args, candidate.command, candidate.aggregate, candidate.random)
        end

        def role_for(earlier, later)
          Violations::MISMATCHED_ROLE if [earlier, later].include?("refuse_role_mismatch")
        end

        # Each command draws from a stream of its own, seeded by its verb, so a command added to a
        # bluebook adds its rows and leaves every other command's rows as they were.
        def candidates(runtime, declaration)
          bluebook = runtime.bluebook(declaration)
          bluebook.aggregates.flat_map do |aggregate|
            aggregate_rows(aggregate, declaration) + entity_rows(aggregate, declaration)
          end
        end

        # @param verb [String] the command's qualified verb
        # @return [SteadyRandom] the stream that command's rows draw from
        def random_for(verb) = SteadyRandom.new(Zlib.crc32(verb))

        def aggregate_rows(aggregate, declaration)
          aggregate.commands.flat_map do |command|
            verb = "#{declaration}::#{aggregate.hecks_name}.#{command.hecks_name}"
            rows_for(command, aggregate, verb, "aggregate", random_for(verb))
          end
        end

        def entity_rows(aggregate, declaration)
          aggregate.entities.flat_map do |entity|
            entity.commands.flat_map do |command|
              verb = "#{declaration}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}"
              random = random_for(verb)
              rows = rows_for(command, aggregate, verb, "entity", random)
              rows.each { |row| row[:args] = identity_args(entity, aggregate, random).merge(row[:args]) }
            end
          end
        end
      end
    end
  end
end
