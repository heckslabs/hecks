# Hecks::Chapters::Rails
#
# Self-describing chapter definition for the hecks_on_rails gem.
# Enumerates every class and module under hecks_on_rails/lib/ as
# aggregates with their key commands.
#
#   domain = Hecks::Chapters::Rails.definition
#   domain.aggregates.map(&:name)
#   # => ["ActiveHecks", "BluebookModelCompat", "AggregateCompat", ...]
#
require "bluebook"

module Hecks
  module Chapters
    module Rails
      def self.definition
        @definition ||= Chapters.definition_from_bluebook("rails")
      end
    end
  end
end
