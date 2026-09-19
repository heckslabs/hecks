module Hecks
  module Fuzzing
    # The one declared set of `FIELDS` that leave a comparison — partition,
    # not filter. Every comparison in lib/hecks/fuzzing that drops a field
    # before comparing two histories names a group here instead of writing
    # its own literal `except(...)` list, so the reason for dropping a field
    # is written exactly once, beside the field.
    #
    # Two specs hold this set honest (spec/fuzzing/nondeterministic_spec.rb):
    # a literal except-list naming any of these fields anywhere under
    # lib/hecks/fuzzing fails the build (the tolerance must be declared
    # here, not re-derived at a call site), and every declared field must
    # actually be produced where its group says — a field nothing emits any
    # more is a stale tolerance and fails too.
    #
    # Groups are keyed by the shape the field rides on, since the same name
    # can be compared on one surface and dropped on another:
    #
    # - `query_row`  — one entry of `Replay.call`'s `:queries`.
    # - `outbox_row` — one row of an `:outbox_traces` entry's `:rows`.
    # - `event`      — an event hash in full `Event#to_h` form (an outbox
    #                  row's `:event`, or a Rust binary's `events` entries,
    #                  string-keyed there).
    # - `history`    — the top-level `Replay.call` history hash itself.
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

      # Lists the nondeterministic field names declared for one comparison group.
      #
      # @param group [Symbol] a key of `FIELDS`, such as `:query_row` or `:event`
      # @return [Array<Symbol>] the field names declared for `group`
      # @raise [KeyError] if `group` names no declared group
      def names(group)
        FIELDS.fetch(group).keys
      end

      # Every declared name, across every group.
      #
      # @return [Array<Symbol>] the union of every group's field names, deduplicated
      def all_names
        FIELDS.values.flat_map(&:keys).uniq
      end

      # `hash` without `group`'s fields — symbol keys, the shape every
      # Ruby-side history carries.
      #
      # @param hash [Hash] a symbol-keyed row, event, or history hash to compare
      # @param group [Symbol] a key of `FIELDS` naming which fields to drop
      # @return [Hash] `hash` with `group`'s declared fields removed
      # @raise [KeyError] if `group` names no declared group
      def strip(hash, group)
        hash.except(*names(group))
      end
    end
  end
end
