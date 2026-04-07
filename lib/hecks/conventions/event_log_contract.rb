# = Hecks::Conventions::EventLogContract
#
# Defines the JSON shape for the /_events HTTP endpoint. Both Ruby
# and Go servers must emit events in this exact format so the smoke
# test can parse them identically regardless of target language.
#
#   Hecks::Conventions::EventLogContract::FIELDS      # => [:name, :occurred_at]
#   Hecks::Conventions::EventLogContract.go_struct    # => Go struct definition
#   Hecks::Conventions::EventLogContract.ruby_mapper  # => Ruby event-to-hash code
#
module Hecks::Conventions
  # Hecks::Conventions::EventLogContract
  #
  # JSON shape contract for the /_events HTTP endpoint across Ruby and Go targets.
  #
  module EventLogContract
    # Every entry in GET /_events must have these fields.
    FIELDS = %i[name occurred_at].freeze

    # JSON key names — used by both targets.
    JSON_KEYS = {
      name: "name",
      occurred_at: "occurred_at",
    }.freeze

    # Go struct definition for the event log entry.
    def self.go_struct
      <<~GO.chomp
        type eventEntry struct {
        \tName string `json:"name"`
        \tOccurredAt string `json:"occurred_at"`
        }
      GO
    end

    # Go code to build an eventEntry from a DomainEvent.
    def self.go_mapper(event_var: "e")
      <<~GO.chomp
        eventEntry{
        \tName: #{event_var}.EventName(),
        \tOccurredAt: #{event_var}.GetOccurredAt().Format(time.RFC3339),
        }
      GO
    end

    # Ruby code to convert an event object to a hash.
    # Returns a string of Ruby code suitable for embedding in generated server.
    def self.ruby_mapper(event_var: "e", mod: nil)
      <<~RUBY.chomp
        { "name" => #{event_var}.class.name.split("::").last,
          "occurred_at" => (#{event_var}.occurred_at.iso8601 rescue nil) }
      RUBY
    end
  end
end
