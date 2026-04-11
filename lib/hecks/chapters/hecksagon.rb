# Hecks::Chapters::Hecksagon
#
# Self-describing chapter definition for the hecksagon gem.
# Enumerates every class and module under hecksagon/lib/ as
# aggregates with their key commands, using namespace, inherits,
# includes, and method_name to enable self-hosting.
#
#   domain = Hecks::Chapters::Hecksagon.definition
#   domain.aggregates.map(&:name)
#   # => ["HecksagonBuilder", "GateBuilder", "AclDefinition", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Hecksagon
      def self.summary = "Hexagonal architecture wiring DSL for Hecks"

      def self.definition
        @definition ||= Chapters.definition_from_bluebook("hecksagon")
      end
    end
  end
end
