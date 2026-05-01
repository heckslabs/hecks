# Hecks::Chapters::Appeal
#
# Appeal is a bluebook project. It boots via Hecks.boot, not as a chapter.
# The bluebook files at hecks/*.bluebook are the source of truth.
#
module Hecks
  module Chapters
    module Appeal
      def self.summary = "Browser-based IDE for domain modeling"

      def self.definition
        @definition ||= Chapters.definition_from_bluebook("appeal")
      end
    end
  end
end
