# = Hecks::Chapters::Packaging
#
# Chapter for selective chapter loading. Registers all available
# chapters and provides a DSL for loading only the ones you need.
#
#   Hecks.chapters :bluebook, :runtime
#   Hecks.chapters :all
#
#   domain = Hecks::Chapters::Packaging.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    # Hecks::Chapters::Packaging
    #
    # Selective chapter loading — register, select, and load framework chapters.
    #
    module Packaging
      def self.summary = "Selective chapter loading and framework packaging"

      def self.definition
        @definition ||= DSL::BluebookBuilder.new("Packaging").tap { |b|
          b.instance_eval do
            aggregate "ChapterRegistry", "All available chapters and their load status" do
              attribute :name, String
              attribute :loaded, String
              command("RegisterChapter") { attribute :name, String }
              command("LoadChapter") { attribute :chapter_id, String }
              command("UnloadChapter") { attribute :chapter_id, String }
            end

            aggregate "ChapterSelector", "DSL for selecting which chapters to load" do
              attribute :selected, list_of(String)
              command("SelectChapters") { attribute :names, String }
              command("SelectAll")
            end

            aggregate "ChapterFile", "HecksChapters file parser" do
              attribute :path, String
              command("ParseChapterFile") { attribute :path, String }
            end
          end
        }.build
      end
    end
  end
end
