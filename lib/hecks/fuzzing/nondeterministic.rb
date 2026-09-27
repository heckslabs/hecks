module Hecks
  module Fuzzing
    # Fields dropped before two histories are compared, declared once per shape they ride on.
    # A literal except-list naming any of them under lib/hecks/fuzzing fails its spec.
    module Nondeterministic
      FIELDS = {
        query_row:  {
          instances_at: "a full state snapshot taken for the query oracle's own use " \
                        "(Properties::Querying); the same state is already compared as `instances`, " \
                        "so keeping it would re-report one instances divergence under every query step"
        }.freeze,
        outbox_row: {
          event_uid:   "`Runtime::Outbox::Fanout#rows_for`'s own SecureRandom.uuid, minted fresh per " \
                       "enqueue and kept off `Event#to_h` — relay bookkeeping, never something the " \
                       "domain produced, so two otherwise-identical replays carry two different uuids",
          delivery_id: "`\"\#{event_uid}/\#{consumer}\"` — inherits event_uid's per-enqueue uuid"
        }.freeze,
        event:      {
          occurred_at: "a wall-clock read; never reproducible byte-for-byte between two independent " \
                       "runs (Replay's own projected `:events` leave it off for the same reason)"
        }.freeze,
        history:    {
          bluebook:  "a live IR object (the first-loaded bluebook) handed to properties — an object " \
                     "identity, not a value, so two boots never compare equal on it",
          bluebooks: "the full live IR map, keyed by domain — object identities, same as `bluebook`"
        }.freeze
      }.freeze

      module_function

      # The field names declared for one comparison group.
      #
      # @raise [KeyError] if `group` names no declared group
      def names(group)
        FIELDS.fetch(group).keys
      end

      # Every declared name, across every group.
      def all_names
        FIELDS.values.flat_map(&:keys).uniq
      end

      # `hash` without `group`'s fields; expects symbol keys.
      #
      # @raise [KeyError] if `group` names no declared group
      def strip(hash, group)
        hash.except(*names(group))
      end
    end
  end
end
