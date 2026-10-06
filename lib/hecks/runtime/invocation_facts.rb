require_relative "errors"
require_relative "refusal_wording"

module Hecks
  module Runtime
    # How an Invocation reads the facts a caller offered: through `with:` or a flat Hash, checked
    # against what the command declares. Mixed into {InvocationBuilder}.
    module InvocationFacts
      # Every candidate fact for `declaring`, as Absent/Null/Present: offered
      # keys first in offered order, then remaining declared attributes as Absent.
      def facts_for(declaring, with:, flat:)
        offered = offered_facts(declaring, with: with, flat: flat)
        facts = offered.each_with_object({}) do |(name, value), found|
          found[name] = value.nil? ? Invocation::Null : Invocation::Present.new(value: value)
        end
        declaring.attributes.each do |attribute|
          name = attribute.name.to_sym
          facts[name] = Invocation::Absent unless facts.key?(name)
        end
        facts
      end

      private

      # `with:` is deliberately strict: a caller choosing the explicit
      # envelope cannot smuggle receiver identity back into the payload,
      # and may not mix it with a flat facts hash. Without `with:`, the
      # flat facts are taken as-is, unread.
      def offered_facts(declaring, with:, flat:)
        refuse_mixed_facts!(with, flat)

        return flat unless with
        raise TypeMismatch, "with: must be a hash of command facts" unless with.is_a?(Hash)

        offered = with.transform_keys(&:to_sym)
        declared = declaring.attributes.map { |attribute| attribute.name.to_sym }
        refuse_unknown_facts!(declaring, offered, declared)
        refuse_absent_facts!(declaring, offered, declared)
        offered
      end

      def refuse_mixed_facts!(with, flat)
        return unless with && !flat.empty?

        raise TypeMismatch,
              "dispatch takes command facts in with:, not both with: and a flat facts hash"
      end

      # Unknown before absent — a `with:` that is both still refuses
      # UnknownArgument first.
      def refuse_unknown_facts!(declaring, offered, declared)
        unknown = (offered.keys - declared).sort
        return if unknown.empty?

        raise UnknownArgument,
              RefusalWording.render_site("UnknownArgument", "unknown_args",
                                         command: declaring.hecks_name, unknown: unknown,
                                         declared: declared)
      end

      # A fact the command `needs`, and an argument its attribute gives a default, are not absent:
      # the interpreter fills them before any refusal reads the arguments.
      def refuse_absent_facts!(declaring, offered, declared)
        absent = required_fact_names(declaring) - offered.keys - filled_fact_names(declaring)
        return if absent.empty?

        raise AbsentArgument,
              RefusalWording.render_site("AbsentArgument", "absent_args",
                                         command: declaring.hecks_name, absent: absent,
                                         declared: declared)
      end

      def required_fact_names(declaring)
        declaring.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym }
      end

      # The facts the interpreter fills in itself: those the command `needs` and those whose
      # attribute declares a default.
      def filled_fact_names(declaring)
        needed = declaring.respond_to?(:needs) ? declaring.needs.map(&:to_sym) : []
        defaulted = declaring.attributes.select { |attribute| attribute.respond_to?(:default) && !attribute.default.nil? }
                             .map { |attribute| attribute.name.to_sym }
        needed + defaulted
      end
    end
  end
end
