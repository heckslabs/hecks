module Hecks
  module QuerySpecification
    module Common
      NullSemantics = Struct.new(:mode, keyword_init: true) do
        def to_h = { mode: mode.to_s }

        # Builds the policy a query has when it never writes `nulls`: each
        # engine orders nulls first ascending and last descending (see `NullPolicy`).
        #
        # @return [NullSemantics] a new instance whose mode is `:native`
        def self.default = new(mode: :native)
      end
    end
  end
end
