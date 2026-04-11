# Hecks::ChapterAliases
#
# Forwards paragraph constants from top-level modules/classes to their
# chapter definitions. After chapters load, Hecks::Runtime (the class)
# and Hecks::Workshop (the class) shadow the chapter modules. This
# installs const_missing hooks so Hecks::Runtime::Mixins still resolves
# to the paragraph module under Chapters.
#
#   Hecks::Runtime::Mixins  # => Chapters::Runtime::Mixins
#   Hecks::Workshop::SandboxParagraph  # => Chapters::Workshop::SandboxParagraph
#
module Hecks
  module ChapterAliases
    # Install const_missing on a class/module so it forwards unknown
    # constants to the corresponding chapter module.
    #
    #   ChapterAliases.install(Runtime, Chapters::Runtime)
    #
    def self.install(target, chapter_module)
      return if target.instance_variable_get(:@_chapter_alias_installed)
      target.instance_variable_set(:@_chapter_alias_installed, true)

      target.define_singleton_method(:const_missing) do |name|
        if chapter_module.const_defined?(name, false)
          chapter_module.const_get(name)
        else
          super(name)
        end
      end
    end
  end
end
