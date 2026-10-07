# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # An aggregate whose records are actions to run later, found by shape. The editor makes
        # and changes the records and never runs an action: a runner elsewhere does.
        #
        # It has a **subject** (a plain `<kind>:<slug>` key, see `KeyKinds`), an **action** from
        # a closed set (`one_of`), a **due time** that is a moment (see `Moment`), a
        # **lifecycle** whose first state moves to at least two states that move nowhere, and a
        # **creating command** that takes the three. The command that reschedules takes the due
        # time; the one that cancels is a destructive move from the first state to a final one;
        # the reason is the first optional plain text left over; the query takes the subject
        # alone. The first such aggregate is the one.
        module Scheduling
          # What a scheduling aggregate's attributes are called in its record: `subject`,
          # `action`, `due`.
          ROLES = %w[subject action due].freeze

          # The widgets of an integer that is a moment.
          MOMENTS = %w[date datetime].freeze

          module_function

          # @param aggregates [Array<Hash{String => Object}>] the aggregates as `Pickers` leaves
          #   them
          # @return [Hash{String => Object}, nil] the scheduling aggregate and its parts; nil when
          #   none
          def read(aggregates)
            aggregates.lazy.filter_map { |agg| shape(agg) }.first
          end

          # @return [Hash{String => Object}, nil] `agg` as the scheduling aggregate, or nil
          def shape(agg)
            parts = parts_of(agg)
            schedule = parts && endings(agg["lifecycle"]).size > 1 && creating(agg, parts)
            return nil unless schedule

            { "aggregate" => agg["name"], "chapter" => agg["chapter"], **parts, "pending" => agg.dig("lifecycle", "default"),
              "schedule" => schedule["name"], **optional(agg, parts, schedule) }.compact
          end

          # @return [Hash{String => Object}, nil] the subject, action, actions and due time, or nil
          def parts_of(agg)
            return nil unless agg["lifecycle"]

            plain = agg["attributes"].reject { |attr| attr["list"] }
            found = [subject_of(agg, plain), plain.find { |attr| attr["options"] }, plain.find { |attr| moment?(attr) }]
            describe(*found) if found.all?
          end

          # @return [Boolean] whether the attribute is an integer that is a moment
          def moment?(attr) = MOMENTS.include?(attr["widget"])

          # @return [Hash{String => Object}] the three attributes' names, and the action's members
          def describe(subject, action, due)
            { "subject" => subject["name"], "action" => action["name"], "actions" => action["options"], "due" => due["name"] }
          end

          # @return [Hash{String => Object}, nil] the attribute that is a key of a kind, the
          #   identity last
          def subject_of(agg, plain)
            plain.select { |attr| attr.dig("picker", "kinds") }.min_by { |attr| attr["name"] == agg["identity"] ? 1 : 0 }
          end

          # @return [Array<String>] the final states the first state moves to: states nothing
          #   moves out of
          def endings(lifecycle)
            moves = lifecycle["transitions"]
            first = moves.select { |move| move["from"].include?(lifecycle["default"]) }.map { |move| move["to"] }.uniq
            first - moves.flat_map { |move| move["from"] }
          end

          # @return [Hash{String => Object}, nil] the creating command that takes the subject,
          #   action and due time
          def creating(agg, parts)
            agg["commands"].find { |cmd| cmd["creates"] && takes?(cmd, parts.values_at(*ROLES)) }
          end

          # @return [Boolean] whether the command takes every one of the named attributes
          def takes?(cmd, names) = (names - cmd["attributes"].map { |attr| attr["name"] }).empty?

          # @return [Hash{String => Object}] the commands, query and reason that may be missing
          def optional(agg, parts, schedule)
            { "reschedule" => rescheduling(agg, parts), "cancel" => cancelling(agg), "query" => querying(agg, parts),
              "reason" => reason(agg, parts), "generated" => generated?(agg, parts, schedule) }
          end

          # @return [String, nil] the command on a record, not a lifecycle move, that takes the
          #   due time
          def rescheduling(agg, parts)
            agg["commands"].find { |cmd| !cmd["creates"] && !move?(agg, cmd) && takes?(cmd, [parts["due"]]) }&.fetch("name")
          end

          # @return [String, nil] the destructive lifecycle move from the first state to a final
          #   one
          def cancelling(agg)
            agg["commands"].find { |cmd| cmd["destructive"] && ends?(agg, cmd) }&.fetch("name")
          end

          # @return [String, nil] the query whose one argument is the subject
          def querying(agg, parts)
            agg["queries"].find { |query| query["attributes"].map { |attr| attr["name"] } == [parts["subject"]] }&.fetch("name")
          end

          # @return [Boolean] whether the command is a lifecycle move
          def move?(agg, cmd) = agg["lifecycle"]["transitions"].any? { |move| move["verb"] == cmd["name"] }

          # @return [Boolean] whether the command moves a first-state record to a final state
          def ends?(agg, cmd)
            lifecycle = agg["lifecycle"]
            final = endings(lifecycle)
            lifecycle["transitions"].any? do |move|
              move["verb"] == cmd["name"] && move["from"].include?(lifecycle["default"]) && final.include?(move["to"])
            end
          end

          # @return [String, nil] the first optional plain text attribute no other part uses
          def reason(agg, parts)
            used = [agg["identity"], *parts.values_at(*ROLES)]
            spare = agg["attributes"].find { |attr| attr["optional"] && !used.include?(attr["name"]) && plain_text?(agg, attr) }
            spare&.fetch("name")
          end

          # @return [Boolean] whether the attribute is one plain text, alone or as a value
          #   object's only part
          def plain_text?(agg, attr)
            return false if %w[list picker options widget].any? { |key| attr[key] }

            parts = agg["valueObjects"][attr["type"]]
            parts ? lone_text?(parts) : attr["kind"] == "text"
          end

          # @return [Boolean] whether the parts are one plain text
          def lone_text?(parts) = parts.size == 1 && parts.first["kind"] == "text" && !parts.first["list"]

          # @return [true, nil] whether the creating command takes an identity that is not the
          #   subject,
          #   which the editor then makes itself
          def generated?(agg, parts, schedule)
            taken = schedule["attributes"].any? { |attr| attr["name"] == agg["identity"] }
            true if taken && agg["identity"] != parts["subject"]
          end
        end
      end
    end
  end
end
