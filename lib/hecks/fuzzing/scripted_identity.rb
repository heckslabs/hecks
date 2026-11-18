require_relative "../runtime/errors"

module Hecks
  module Fuzzing
    # An identity port whose ids are written down: each request answers the next one in the list.
    #
    # A conformance fixture names the ids its `identity_generation` port will hand out, so a runtime
    # that mints a run key mints the same one in every engine. When the list is spent the port
    # answers nothing, as a registry with no identity adapter bound does.
    class ScriptedIdentity
      # @param ids [Array<String>] the ids to hand out, in order
      def initialize(ids)
        @ids = ids.dup
      end

      # @return [String] the next scripted id
      # @raise [Runtime::WiringError] when every scripted id has been handed out
      def uuid
        @ids.shift or raise Runtime::WiringError, "the scripted identity port has no id left to mint"
      end
    end
  end
end
