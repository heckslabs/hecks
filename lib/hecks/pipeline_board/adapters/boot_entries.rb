# frozen_string_literal: true

require_relative "../../hecks/adapters/boot_budget"

module Hecks
  module Adapters
    # One read of the usage record for a whole boots reading. The day's hours, the boot share and
    # the storms each ask for entries since some time; the record is the launcher's own and holds
    # a line for every run, so reading it once for each asks the disk and the parser for the same
    # work over and over. This answers every ask from the widest read made since {#renew}.
    class BootEntries
      # @param source [#call, nil] answers the entries since a time; the record's tail when nil
      def initialize(source = nil)
        @source = source || BootBudget::UsageTail.method(:since)
        renew
      end

      # Forgets the read, so the next ask reads the record afresh.
      # @return [void]
      def renew
        @since = nil
        @entries = nil
      end

      # @param since [Time] the start of the window asked for
      # @return [Array] the entries of the widest read, which hold every entry since `since`
      def call(since)
        return @entries if @entries && @since <= since

        @since = since
        @entries = @source.call(since)
      end
    end
  end
end
