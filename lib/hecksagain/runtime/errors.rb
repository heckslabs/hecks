
module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end
    class LifecycleRefused < StandardError; end
    class TypeMismatch < StandardError; end
  end
end
