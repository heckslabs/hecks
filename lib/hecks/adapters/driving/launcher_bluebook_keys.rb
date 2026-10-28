module Hecks
  module Adapters
    module Driving
      # The `launcher` setting's keys that name bluebooks. `bluebooks` and `maintainer_bluebooks`
      # are the keys; `chapters` and `maintainer_chapters` are their retired spellings, still read,
      # each use saying on standard error which key replaces it (ADR 0134).
      module LauncherBluebookKeys
        module_function

        # @param settings [Hash] the bluebook's `launcher` setting
        # @param key [Symbol] the key that names bluebooks
        # @param retired [Symbol] its retired spelling
        # @return [Array<String>] the names under both keys
        def names(settings, key, retired)
          warn "hecks: the launcher setting #{retired} is deprecated, use #{key}" if settings.key?(retired)
          (Array(settings[key]) + Array(settings[retired])).map(&:to_s)
        end
      end
    end
  end
end
