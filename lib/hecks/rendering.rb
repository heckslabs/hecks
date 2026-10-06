require "json"

module Hecks
  # How a value reads inside a refusal; the wording is contract, pinned by the corpus.
  #
  # `inspect` and JSON disagree on composites, so refusals use JSON throughout.
  module Rendering
    module_function

    # Renders a value the way it should read inside a refusal message.
    #
    # @param value [Object] the value to render
    # @return [String] `"nil"` for nil, JSON for a Hash/Array or a duck-typed value
    #   object (unwrapped to its bare scalar when it has exactly one field), or
    #   `value.inspect` for anything else
    def describe(value)
      case value
      when nil then "nil"
      when Hash, Array then JSON.generate(value)
      else describe_other(value)
      end
    end

    # Duck-typed on `to_h`: naming Runtime::Value here would be circular, since
    # it requires this file. A one-field wrapper unwraps to its bare scalar.
    #
    # @param value [Object] anything but nil, a Hash or an Array
    # @return [String] the value object's field or fields as described, or `value.inspect`
    def describe_other(value)
      return value.inspect unless value.respond_to?(:to_h)

      fields = value.to_h
      fields.size == 1 ? describe(fields.values.first) : JSON.generate(fields)
    end
  end
end
