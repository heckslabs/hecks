module Hecksagain
  # The declarative shape of an ask — what a query says, held apart from
  # any engine that answers it. `common/` is the vocabulary every ask
  # shares; `read_model/` the read-model-specific specification.
  module QuerySpecification
  end
end

require_relative "query_specification/common/specification"
require_relative "query_specification/common/null_policy"
require_relative "query_specification/common/dsl"
require_relative "query_specification/field_path"
require_relative "query_specification/hop_path"
require_relative "query_specification/read_model/specification"
