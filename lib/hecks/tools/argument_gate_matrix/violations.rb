# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module ArgumentGateMatrix
      # How an input is bent to violate one argument gate: each step mutates the arguments and says
      # what it broke, or answers nil when the command cannot violate it.
      module Violations
        # `to:`/`with:` are dispatch envelope keywords, so an attribute with either name is read as
        # a route; corrupting it would exercise envelope parsing, not an argument gate.
        ENVELOPE_KEYS = %w[to with].freeze

        MISMATCHED_ROLE = "a role this caller does not hold"

        # A well-typed string no `one_of` admits, so a closed set refuses on membership.
        NON_MEMBER = "not a declared member"

        # @param command [Object] a command construct
        # @return [Array] the attributes a wrong value can be put in
        def corruptible(command)
          command.attributes.reject { |a| a.list? || a.reference? || ENVELOPE_KEYS.include?(a.name.to_s) }
        end

        # @param command [Object] a command construct
        # @return [Array] the attributes that can be left out
        def droppable(command)
          command.attributes.reject { |a| a.optional? || a.list? || ENVELOPE_KEYS.include?(a.name.to_s) }
        end

        # Mutates `args` to violate `step`; returns a description of the violation, or nil if the
        # command cannot violate it.
        def violate!(step, args, command, aggregate, random)
          case step
          when "refuse_unknown_arguments" then violate_unknown!(args, random)
          when "refuse_absent_arguments"  then violate_absent!(args, command)
          when "normalize_args"           then violate_normalize!(args, command, aggregate, random)
          when "refuse_role_mismatch"     then MISMATCHED_ROLE
          when "resolve_references"       then violate_reference!(args, command)
          # The world is empty, so every acting command addresses a missing record.
          when "hydrate", "hydrate_parent" then "no record exists"
          end
        end

        def violate_unknown!(args, random)
          name, value = Hecks::Fuzzing::InvalidValueGenerator.undeclared_argument(random: random)
          args[name.to_s] = value
          name.to_s
        end

        def violate_absent!(args, command)
          dropped = droppable(command).first or return nil

          args.delete(dropped.name.to_s)
          dropped.name.to_s
        end

        # Corrupts one attribute with a wrong value both engines word identically. It avoids
        # `InvalidValueGenerator.corrupt`, whose composite-value-object and Array shapes render
        # differently in Ruby and Rust, and corrupts a declared value-object field instead.
        def violate_normalize!(args, command, aggregate, _random)
          attribute = corruption_target(command, args)
          return nil unless attribute

          wrong = wrong_value(attribute, args[attribute.name.to_s], aggregate)
          return nil if wrong.nil?

          args[attribute.name.to_s] = wrong
          attribute.name.to_s
        end

        # The attribute already carrying a value, or else the first one that can be corrupted.
        def corruption_target(command, args)
          corruptible(command).find { |a| args.key?(a.name.to_s) } || corruptible(command).first
        end

        # A value `attribute` refuses, or nil when none can be made from `current`.
        def wrong_value(attribute, current, aggregate)
          value_object = Hecks::Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
          return mistyped_scalar(attribute.type) if value_object.nil?

          corrupt_field(value_object, current) if current.is_a?(Hash)
        end

        # `current` with one declared field of the value object given a wrong value.
        def corrupt_field(value_object, current)
          field = value_object.attributes.find { |f| current.key?(f.name.to_s) } or return nil

          current.merge(field.name.to_s => value_object.closed_set? ? NON_MEMBER : mistyped_scalar(field.type))
        end

        # For a String field a plain scalar is worded differently by Ruby and Rust, so an empty
        # Hash (the branch they share) stands in as the wrong value.
        def mistyped_scalar(type_name)
          type_name.to_s == "String" ? {} : "not a #{type_name.to_s.downcase}"
        end

        def violate_reference!(args, command)
          reference = command.attributes.find(&:reference?) or return nil

          args[reference.name.to_s] = "no-such-#{reference.type.target_name.to_s.downcase}"
          reference.name.to_s
        end
      end
    end
  end
end
