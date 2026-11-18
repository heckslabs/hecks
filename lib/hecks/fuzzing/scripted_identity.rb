require_relative "../runtime/errors"
require_relative "../ports/identity_generation"

module Hecks
  module Fuzzing
    # An identity port whose ids are written down: each request answers the next one in the list.
    #
    # A conformance fixture names the ids its `identity_generation` port will hand out, so a runtime
    # that mints a run key mints the same one in every engine. When the list is spent the port
    # answers nothing, as a registry with no identity adapter bound does.
    class ScriptedIdentity
      # A stand-in for `Runtime::AdapterLookup.standing_in` that answers the identity port with
      # `ids` and asks `others` for every other port.
      #
      # @param ids [Array<String>] the ids to hand out, in order
      # @param others [#call] answers `(port_name, asked)` for every port but the identity port
      # @return [Proc] the stand-in
      def self.over(ids, others)
        scripted = new(ids)
        lambda do |port_name, asked|
          port_name.to_s == Ports::IdentityGeneration::NAME ? scripted : others.call(port_name, asked)
        end
      end

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
