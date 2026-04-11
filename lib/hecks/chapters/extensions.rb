# = Hecks::Chapters::Extensions
#
# Self-describing chapter for Hecks extension infrastructure. Covers
# all pluggable extensions: HTTP serving, persistence, auth, ACL,
# web explorer, tenancy, metrics, PII, and more.
#
#   domain = Hecks::Chapters::Extensions.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)
    # Hecks::Chapters::Extensions
    #
    # Bluebook chapter defining all pluggable Hecks extensions: HTTP serving, persistence, auth, tenancy, and more.
    #
    module Extensions
      def self.definition
        @definition ||= Chapters.definition_from_bluebook("extensions")
      end
    end
  end
end
