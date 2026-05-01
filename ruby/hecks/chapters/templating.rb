# Hecks::Chapters::Templating
#
# Self-describing chapter for the HecksTemplating component. Covers
# naming convention helpers and browser-style HTTP smoke testing.
#
#   domain = Hecks::Chapters::Templating.definition
#   domain.aggregates.map(&:name)
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    # Hecks::Chapters::Templating
    #
    # Bluebook chapter defining the HecksTemplating component: naming helpers and HTTP smoke testing.
    #
    module Templating
      def self.definition
        @definition ||= Chapters.definition_from_bluebook("templating")
      end
    end
  end
end
