module Hecks
  # The fuzzing toolkit bin/fuzz and bin/generate drive. Not required by
  # lib/hecks.rb on purpose — a booted domain never needs it.
  module Fuzzing
  end
end

require_relative "fuzzing/value_generator"
require_relative "fuzzing/invalid_value_generator"
require_relative "fuzzing/sequence_generator"
require_relative "fuzzing/replay"
require_relative "fuzzing/properties"
