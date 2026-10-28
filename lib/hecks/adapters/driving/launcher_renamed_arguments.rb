module Hecks
  module Adapters
    module Driving
      # The `renamed_arguments` of a bluebook's `launcher` setting: a retired argument name mapped
      # to the name that replaced it (`{ "chapter" => "bluebook" }`). A command line that still
      # spells the old name is read as the new one, and says so on standard error, but only for a
      # command that declares the new name and not the old, so a command that keeps the old name
      # is left alone (ADR 0134).
      module LauncherRenamedArguments
        module_function

        # @param spec [Hash{Symbol => Object}] one command's entry from `Projector::CliProjector`
        # @param words [Array<String>] the words after the command
        # @param launcher [Hash, nil] the bluebook's `launcher` setting
        # @return [Array<String>] `words`, with a retired argument name respelled
        def apply(spec, words, launcher)
          renamed = launcher && launcher[:renamed_arguments]
          return words if renamed.nil? || renamed.empty?

          paths = spec[:arguments].map { |argument| argument[:path] }
          words.map { |word| respell(word, renamed, paths) }
        end

        # @return [String] the word, with the retired name at its front replaced by its new name
        def respell(word, renamed, paths)
          name, value = word.split("=", 2)
          return word if value.nil? || word.start_with?("--")

          old, new = renamed.find { |from, _| name == from || name.start_with?("#{from}.") }
          return word unless replaces?(paths, old, new)

          warn "hecks: the argument #{old} is deprecated, use #{new}"
          "#{new}#{name.delete_prefix(old)}=#{value}"
        end

        # @return [Boolean] whether the command dropped the old name and declares the new one
        def replaces?(paths, old, new)
          !old.nil? && !declares?(paths, old) && declares?(paths, new)
        end

        # @return [Boolean] whether a command declares an argument of that name, or one of its
        #   fields
        def declares?(paths, name)
          paths.any? { |path| path == name || path.start_with?("#{name}.") }
        end
      end
    end
  end
end
