require_relative "../naming"

module Hecks
  module Storehouse
    # Which chapter a command or query name speaks to, read the way the CLI reads a line: the
    # booted domain's own chapter, or a chapter its hecksagon attaches when the name starts with
    # that chapter's word and a space (`bulk bulk_run.request` reaches the attached Bulk chapter).
    # Extended onto `Storehouse`.
    module ChapterWords
      # The chapter `name` speaks to, and the name within that chapter.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param name [String, Symbol] a command or query name, optionally led by a chapter word
      # @return [Array(Bluebook::Chapter, String)] the chapter, and the name with its chapter word dropped
      # @raise [Runtime::NotFound] if the boot loaded no bluebook
      def chapter_and_name(runtime, name)
        word, rest = name.to_s.split(" ", 2)
        attached = rest && attached_chapter(runtime, word)
        attached ? [runtime.bluebook(attached), rest] : [bluebook_for(runtime), name.to_s]
      end

      # The name of the chapter the booted domain attaches under `word`, or nil.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param word [String] a chapter's snake-cased name, such as `"bulk"`
      # @return [String, nil] the attached chapter's name
      def attached_chapter(runtime, word)
        own = bluebook_for(runtime)
        Array(runtime.hecksagon(own.name)&.member_chapters).find { |chapter| Naming.snake(chapter) == word }
      end
    end
  end
end
