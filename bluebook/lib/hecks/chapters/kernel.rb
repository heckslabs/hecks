# Hecks::Chapters::Kernel
#
# Self-describing chapter for the bootstrap infrastructure. Models the
# DSL builders, domain model IR, registries, core utilities, and the
# chapter system itself as aggregates. This chapter is descriptive only
# for interpreted Ruby (require_relative still loads the kernel), but
# the compiled binary (Hecks v0) will use these definitions for chapter
# dispatch loading.
#
# Organized into paragraphs: DslBuilders, DomainModel, Registries,
# Core, ChapterSystem.
#
#   domain = Hecks::Chapters::Kernel.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Kernel
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Kernel").tap { |b|
          b.instance_eval do
            aggregate "BootstrapKernel", "Root of the kernel infrastructure that makes chapter-driven loading possible" do
              attribute :name, String
              command("Boot") { attribute :base_dir, String }
              command("LoadChapters") { attribute :root, String }
            end
          end

          Chapters.define_paragraphs(Kernel, b)
        }.build
      end
    end
  end
end
