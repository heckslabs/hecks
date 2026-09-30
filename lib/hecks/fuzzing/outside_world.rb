# frozen_string_literal: true

require_relative "../runtime/errors"

module Hecks
  module Fuzzing
    # What a replay asks in place of a port's adapter: an object that refuses every question.
    #
    # A domain's adapters reach outside the process, and the chapters of this repository that
    # drive tools (the shell, git, child processes, the file system) would run them for real from
    # a generated sequence. A replay checks the domain's own rules, so the adapter never runs:
    # the operation is refused, which a port operation records as its `refuses` event and a query
    # answered by a port raises like any domain refusal.
    #
    # The refusal is a `GivenNotMet` for the runtime's sake but not one a `given` declares, and no
    # property that reads guard descriptions quotes it.
    class OutsideWorld
      # The refusal every question to a stand-in ends in.
      class Refused < Runtime::GivenNotMet; end

      # @param port_name [String] the port whose adapter this stands in for
      # @param asked [String] what was being asked, worded into the refusal
      # @return [OutsideWorld] the stand-in
      def self.call(port_name, asked)
        new(port_name, asked)
      end

      # @param port_name [String] the port whose adapter this stands in for
      # @param asked [String] what was being asked, worded into the refusal
      def initialize(port_name, asked)
        @port_name = port_name
        @asked = asked
      end

      # Every method a port could declare exists here, and refuses.
      def respond_to_missing?(_name, _include_private = false) = true

      # @raise [Refused] always
      def method_missing(name, *, **)
        raise Refused, "#{@asked} was not asked of the #{@port_name} port's adapter: a replay runs " \
                       "no adapter (#{name})"
      end
    end
  end
end
