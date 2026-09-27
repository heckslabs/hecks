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
      else
        # Duck-typed on `to_h`: naming Runtime::Value here would be circular, since
        # it requires this file. A one-field wrapper unwraps to its bare scalar.
        if value.respond_to?(:to_h) && !value.is_a?(Hash) && !value.is_a?(Array)
          fields = value.to_h
          fields.size == 1 ? describe(fields.values.first) : JSON.generate(fields)
        else
          value.inspect
        end
      end
    end
  end
end
