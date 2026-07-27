# Runtime errors — the ways a dispatch can refuse.
#
# They live together, and apart from any one interpreter, because a caller
# rescues them without caring which stage raised: a spec asserting GivenNotMet
# should not have to know whether guarding belongs to the door or to the
# command interpreter. Moving a method between those two must never move the
# constant a rescue names.
#
#   rescue Hecksagain::Runtime::GivenNotMet => e

module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end
    # A value arrived in a shape the domain does not admit — a scalar where a
    # multi-field value object was declared. Loud, because the alternative is
    # storing it raw and answering nil to every dotted read of it.
    class TypeMismatch < StandardError; end
  end
end
