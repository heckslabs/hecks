module Hecksagain
  module Runtime
    # THE SCALAR AN IDENTITY PATH NAMES.
    #
    # An identity is DECLARED as a path — `identified_by { number.value }` — and
    # this is the one place that reads one. It follows the path and nothing else.
    #
    # What it replaced was `Value.identifier`, which opened a one-field value
    # object and took whatever was inside : that let `identified_by :number` pass
    # for an identity, with the runtime guessing which field had been meant. The
    # guess is gone. A declaration that names no field is now refused when the
    # bluebook loads (`an aggregate that is identified names a field`, `an entity
    # is known by a field`), so by the time anything is dispatched there is
    # always a path here to follow.
    #
    # Usage:
    #
    #   Identity.scalar("number.value", account_number_value_object)  # => "acct-1"
    #
    module Identity
      module_function

      # The head names the ATTRIBUTE and is consumed by whoever looked the value
      # up; what is left is the walk down into it. A path with no fields to walk
      # — an aggregate that declares no identity and falls back to `id` — hands
      # back what it was given, because there is nothing declared to dig for.
      def scalar(path, held)
        _head, *fields = path.to_s.split(".")
        return held if fields.empty?

        fields.reduce(Value.materialize(held)) do |dug, field|
          dug.is_a?(Hash) ? (dug[field.to_sym] || dug[field]) : nil
        end
      end
    end
  end
end
