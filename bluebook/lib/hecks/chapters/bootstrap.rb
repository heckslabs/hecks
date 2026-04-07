# Hecks::Chapters::Bootstrap
#
# The bootstrap kernel: the minimal set of files that must load via
# require_relative before any chapter can describe itself. These are
# the DSL builders, domain model IR, tokenizer, and chapter system
# that make chapter-driven loading possible.
#
# In Stage 0 (interpreted Ruby), these files load via require_relative.
# In Stage 1 (compiled), these become chapter-loaded like everything else.
# The Bootstrap chapter is the bridge between stages.
#
#   domain = Hecks::Chapters::Bootstrap.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Bootstrap
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Bootstrap").tap { |b|
          b.aggregate "Tokenizer", "Splits command argument strings into typed tokens for DSL parsing" do
            command("Tokenize") { attribute :input, String }
          end

          b.aggregate "ChapterSystem", "Infrastructure for self-describing chapter loading: paragraph discovery, aggregate requiring, and chapter wiring" do
            command("RequireParagraphs") { attribute :chapter_file, String }
            command("LoadAggregates") { attribute :paragraph_module, String; attribute :base_dir, String }
            command("LoadChapter") { attribute :chapter_module, String; attribute :base_dir, String }
            command("DefineParagraphs") { attribute :chapter_module, String }
          end

          b.aggregate "DomainBuilder", "Top-level DSL entry point: builds domain IR from block syntax" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "BluebookBuilder", "Composes chapters into a Bluebook with cross-chapter policies and shared event bus" do
            command("Build") { attribute :name, String }
          end

          Chapters.define_paragraphs(Bootstrap, b)
        }.build
      end
    end
  end
end
