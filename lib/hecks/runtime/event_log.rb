# frozen_string_literal: true

module Hecks
  module Runtime
    # The registry's list of emitted events. It is an Array in every respect; the addition is two
    # observers, told of each event as it is appended and of each policy reaction as it is logged,
    # which is how an opt-in tap sees what the runtime dispatched.
    class EventLog < Array
      # @return [#call, nil] told of each event appended; nil when nothing watches
      attr_accessor :observer

      # @return [#call, nil] told of each policy reaction with its record and the identity of the
      #   event it answered; nil when nothing watches
      attr_accessor :reaction_observer

      # Appends an event and tells the observer of it.
      #
      # @param event [Runtime::Event] the emitted event
      # @return [EventLog] self
      def <<(event)
        super
        observer&.call(event)
        self
      end
    end
  end
end
