# frozen_string_literal: true

module Hecks
  module Adapters
    module InProcessOperations
      # The domain a follow names: a directory, or a bluebook that the Hecks domain boots.
      #
      # A word that holds a path separator is a directory. A bare word is first a bluebook name of
      # the Hecks domain (`Hecks`, `Tickets`, `agents`, `quality_control`), which boots that
      # domain, so its aggregate filter picks the log; then a directory beside the caller; and
      # otherwise it is refused with the names it could have been. The names are read from the boot
      # a name needs anyway, so a refusal costs no boot a follow would not have made.
      module DomainNames
        # The Hecks domain's directory, the one the launcher boots, in a checkout or a gem.
        HOME = File.expand_path("../..", __dir__)

        private

        # The booted registry of the domain `domain` names.
        #
        # @raise [Runtime::NotFound] when the word is no bluebook name and no directory
        def followed_registry(domain)
          word = plain(domain).to_s
          return boot(domain).registry if path_word?(word)

          home = boot(HOME).registry
          return home if names_a_bluebook?(home, word)
          return boot(word).registry if Dir.exist?(word)

          raise Runtime::NotFound, unknown_domain(word, home)
        end

        # An empty word (the enclosing domain) or one holding a path separator is a directory.
        def path_word?(word) = word.empty? || word.include?(File::SEPARATOR)

        # Whether `word` names a bluebook the registry holds, in any case or in its snake form.
        def names_a_bluebook?(registry, word)
          registry.bluebooks.keys.any? { |name| name.casecmp?(word) || Naming.snake(name) == word }
        end

        def unknown_domain(word, home)
          "no such domain #{word.inspect}: follow takes a domain directory or one of " \
            "#{bluebook_names(home).join(", ")}"
        end

        # The names of the bluebooks the registry holds, sorted.
        def bluebook_names(registry) = registry.bluebooks.keys.sort
      end
    end
  end
end
