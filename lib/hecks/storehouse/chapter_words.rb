require_relative "../naming"

module Hecks
  module Storehouse
    # Which bluebook a command or query name speaks to, read the way the CLI reads a line: the
    # booted domain's own bluebook, or a bluebook its hecksagon attaches when the name starts with
    # that bluebook's word and a space (`bulk bulk_run.request` reaches the attached Bulk bluebook).
    # Extended onto `Storehouse`.
    module ChapterWords
      # The bluebook `name` speaks to, and the name within that bluebook.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param name [String, Symbol] a command or query name, optionally led by a bluebook word
      # @return [Array(Bluebook::Declaration, String)] the bluebook, and the name with its bluebook word
      #   dropped
      # @raise [Runtime::NotFound] if the boot loaded no bluebook
      def chapter_and_name(runtime, name)
        word, rest = name.to_s.split(" ", 2)
        attached = rest && attached_chapter(runtime, word)
        attached ? [runtime.bluebook(attached), rest] : [bluebook_for(runtime), name.to_s]
      end

      # The name of the bluebook the booted domain attaches under `word`, or nil.
      #
      # @param runtime [Runtime::Dispatcher] the booted domain
      # @param word [String] a bluebook's snake-cased name, such as `"bulk"`
      # @return [String, nil] the attached bluebook's name
      def attached_chapter(runtime, word)
        own = bluebook_for(runtime)
        Array(runtime.hecksagon(own.name)&.member_chapters).find { |chapter| Naming.snake(chapter) == word }
      end
    end
  end
end
