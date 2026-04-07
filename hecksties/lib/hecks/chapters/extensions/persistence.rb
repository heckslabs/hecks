# = Hecks::Chapters::Extensions::PersistenceChapter
#
# Self-describing sub-chapter for persistence extensions:
# filesystem store and repository variants.
#
#   Hecks::Chapters::Extensions::PersistenceChapter.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      module PersistenceChapter
        def self.define(b)
          b.aggregate "FilesystemRepository", "JSON file-based persistence" do
            command("Save") { attribute :aggregate_name, String; attribute :data, String }
            command("Load") { attribute :aggregate_name, String; attribute :id, String }
            command("Delete") { attribute :id, String }
          end

          b.aggregate "FileAdapter", "Low-level file read/write adapter" do
            command("Write") { attribute :path, String; attribute :content, String }
            command("Read") { attribute :path, String }
          end
        end
      end
    end
  end
end
