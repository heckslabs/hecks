module Hecksagain
  module Bluebook
    # The intermediate representation — the typed graph a parsed bluebook
    # becomes, one declaration kind per file. Order matters only for
    # reading: each file is a bag of Structs with no load-time
    # cross-references.
    module IR
    end
  end
end

# Every declaration file extends Construct at class body — and Query
# subclasses QuerySpecification's Options there too. They cannot say so
# themselves (contents frozen) — the namespace file says it for them.
require_relative "../construct"
require_relative "../query_specification"

require_relative "ir/reference"
require_relative "ir/attribute"
require_relative "ir/value_object"
require_relative "ir/command"
require_relative "ir/lifecycle"
require_relative "ir/query"
require_relative "ir/read_model"
require_relative "ir/entity"
require_relative "ir/policy"
require_relative "ir/process_manager"
require_relative "ir/aggregate"
require_relative "ir/bluebook"
require_relative "ir/hexagon"
require_relative "ir/translation"
