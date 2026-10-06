require_relative "../fuzzing"
require_relative "mutation/run"

module Hecks
  module Fuzzing
    # Mutation testing of a domain's own checks: small semantic changes to its bluebooks, each run
    # past the fuzz properties and the corpus script to see whether anything fails. A mutant nothing
    # fails on is a hole in the checks. See `Mutation::Run`.
    module Mutation
    end
  end
end
