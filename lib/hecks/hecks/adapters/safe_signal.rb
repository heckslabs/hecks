# frozen_string_literal: true

module Hecks
  module Adapters
    # The one place a process or a process group is sent a signal.
    #
    # `Process.kill(sig, -1)` signals every process the user owns, and `0` signals the caller's own
    # group, so a target that is nil, zero, one or negative never reaches the kernel. The helper
    # refuses such a target by name, and refuses the caller's own group, before it signals.
    module SafeSignal
      # Raised, with the refusal in its message, when a target is not one this process may signal.
      class Refused < ArgumentError; end

      # The signaller a caller gets unless it passes another: the kernel's.
      KERNEL = ->(name, target) { Process.kill(name, target) }

      # Signals the process group a child leads.
      #
      # @param name [String, Symbol, Integer] the signal
      # @param group [Integer] the group's id, which is its leader's pid, above 1 and not our own
      # @param killer [#call] sends the signal to a target; a stub in a spec
      # @raise [Refused] when the group is nil, not an integer, 1 or below, or this process's own
      # @return [Object] what the signaller answers
      def self.to_group(name, group, killer: KERNEL)
        target = checked(group, "group")
        raise Refused, "refused: group #{group} is its own group, which a signal never goes to" if target == Process.getpgrp

        killer.call(name, -target)
      end

      # Signals one process.
      #
      # @param name [String, Symbol, Integer] the signal
      # @param pid [Integer] the process id, above 1
      # @param killer [#call] sends the signal to a target; a stub in a spec
      # @raise [Refused] when the pid is nil, not an integer, or 1 or below
      # @return [Object] what the signaller answers
      def self.to_process(name, pid, killer: KERNEL)
        killer.call(name, checked(pid, "process"))
      end

      # Asks whether a process stands, by the null signal, which delivers nothing to anyone, so
      # process 1 may be asked about though it is never signalled.
      #
      # @param pid [Integer] the process id; nil, a non-integer, zero or a negative answers false
      # @param killer [#call] sends the signal to a target; a stub in a spec
      # @return [Boolean] false when the id is refused or the process is gone, else true
      def self.standing?(pid, killer: KERNEL)
        return false unless pid.is_a?(Integer) && pid.positive?

        killer.call(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue SystemCallError
        true
      end

      # @return [Integer] the id, when it is an integer above 1
      def self.checked(id, kind)
        return id if id.is_a?(Integer) && id > 1

        raise Refused, "refused: #{kind} #{id.inspect} is not one this process may signal (only ids above 1)"
      end
      private_class_method :checked
    end
  end
end
