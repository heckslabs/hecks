# Hecks::Chapters::Kernel::ChapterSystemParagraph
#
# Paragraph describing the chapter system itself: paragraph loading,
# aggregate loading from chapters, and chapter-to-implementation wiring.
# This is the meta-description — the chapter system describing itself.
#
#   Hecks::Chapters::Kernel::ChapterSystemParagraph.define(builder)
#
module Hecks
  module Chapters
    module Kernel
      module ChapterSystemParagraph
        def self.define(b)
          b.aggregate "ChapterSystem", "Infrastructure for self-describing chapter definitions with paragraph and aggregate loading" do
            command("RequireParagraphs") { attribute :chapter_file, String }
            command("LoadAggregates") { attribute :paragraph_module, String; attribute :base_dir, String }
            command("LoadChapter") { attribute :chapter_module, String; attribute :base_dir, String }
            command("DefineParagraphs") { attribute :chapter_module, String }
          end
        end
      end
    end
  end
end
