# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # The `Seats` port's adapter for `Seat`: writes the role a hand-started session registered as
    # one line of `seats/<session>` under the directory the Bash guard hook reads, and nothing
    # else. It decides nothing: whether the role is guarded is `Role.guard`'s answer from the
    # routing rows, so a role with none (the owner's) leaves the session unguarded. Registering
    # again overwrites the line, so a session that changes role is guarded as its newest one.
    class SeatMarker
      SAFE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `dir:` the directory holding the seat files
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @dir = settings[:dir] || File.join(ENV.fetch("HECKS_SEATS_DIR", File.join(Dir.home, ".claude", "hecks-dev", "seats")))
      end

      # @param session [Hash, String] the registered session's id
      # @param role [Hash, String] the role it registered as
      # @return [Hash{Symbol => Hash}] `kept:` the path written
      # @raise [ArgumentError] when the session or role is not a plain word
      def seat(session:, role:, **)
        id = plain(session)
        name = plain(role)
        raise ArgumentError, "a seat is a plain session id and role" unless id.match?(SAFE) && name.match?(SAFE)

        FileUtils.mkdir_p(@dir)
        path = File.join(@dir, id)
        File.write(path, "#{name}\n")
        { kept: { value: path } }
      end

      private

      def plain(value) = (value.is_a?(Hash) ? value.fetch(:value) { value["value"] } : value).to_s
    end
  end
end
