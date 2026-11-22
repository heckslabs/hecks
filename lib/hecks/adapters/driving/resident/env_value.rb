require "digest"

module Hecks
  module Adapters
    module Driving
      module Resident
        # What a variable's value comes to when a line's environment is compared with the
        # resident's. Most values count as they are; some are cleaned of what changes nothing
        # the code loads: `RUBYLIB` of the rbenv hook directory and a Bundler gem's library,
        # `RUBYOPT` holding only Bundler's setup and warning levels, `BUNDLE_GEMFILE` naming the
        # checkout's own Gemfile or a copy whose Gemfile and `Gemfile.lock` hold the same bytes
        # (the gems are the lock's), and `GEM_HOME` naming the directory gems resolve to without
        # it (by real path). A line's child runs under the line's own environment. Anything else
        # keeps the whole value and is refused on a difference; `GEM_PATH` is never cleaned,
        # since it adds to the gem set. It uses only the standard library: the client runs
        # before anything loads.
        module EnvValue
          # The variable whose value is cleaned.
          LIBRARY_PATH = "RUBYLIB".freeze
          # The entries a Ruby version manager adds for its own hooks.
          MANAGER = %r{/rbenv\.d/}
          # The library directory of Bundler installed as a gem.
          BUNDLER_LIB = %r{/gems/bundler-\d[\d.]*/lib\z}
          # The options of a `RUBYOPT` that change nothing about what loads.
          HARMLESS_OPTION = %r{\A(-r(\S*/)?bundler/setup|-I\S*/gems/bundler-\d[\d.]*/lib|-W[012]?|-w)\z}

          module_function

          # @param name [String] the variable
          # @param value [String, nil] its value, nil when it is not set
          # @param root [String, nil] the checkout the resident serves, for `BUNDLE_GEMFILE`
          # @return [String, nil] the value to compare, cleaned as the module comment says (nil
          #   when nothing else is left), any other value as it is
          def of(name, value, root = nil)
            return value unless value

            case name
            when LIBRARY_PATH then library_path(value)
            when "RUBYOPT" then options(value)
            when "BUNDLE_GEMFILE" then gemfile(value, root)
            when "GEM_HOME" then gem_home(value)
            else value
            end
          end

          # @return [String, nil] the entries that are not a manager's or Bundler's
          def library_path(value)
            kept = value.split(":").reject { |entry| entry.empty? || entry.match?(MANAGER) || entry.match?(BUNDLER_LIB) }
            kept.empty? ? nil : kept.join(":")
          end

          # @return [String, nil] nil when every option is harmless, the value otherwise
          def options(value)
            value.split.all? { |option| option.match?(HARMLESS_OPTION) } ? nil : value
          end

          # @return [String, nil] nil when the Gemfile is the checkout's own, the value otherwise
          def gemfile(value, root)
            root && (same_path?(value, root) || same_bundle?(value, root)) ? nil : value
          end

          # @return [Boolean] whether the Gemfile is the checkout's own, by real path
          def same_path?(value, root) = canonical(value) == canonical(File.join(root, "Gemfile"))

          # @return [Boolean] whether the Gemfile and its lock hold the same bytes as the
          #   checkout's, so a copy resolves to the same gems; false when either lock is missing
          def same_bundle?(value, root)
            mine = bundle_digest(File.join(root, "Gemfile"))
            !mine.nil? && mine == bundle_digest(value)
          end

          # @return [String, nil] a digest of the Gemfile and its lock, nil when either is unread
          def bundle_digest(gemfile)
            Digest::SHA256.hexdigest([File.binread(gemfile), File.binread("#{gemfile}.lock")].join("\0"))
          rescue SystemCallError
            nil
          end

          # @return [String, nil] nil when `GEM_HOME` is the directory gems resolve to without it,
          #   the value otherwise
          def gem_home(value)
            canonical(value) == canonical(Gem.default_dir) ? nil : value
          end

          # @return [String] the real path, or the expanded one when nothing is there
          def canonical(path)
            File.realpath(path)
          rescue SystemCallError
            File.expand_path(path)
          end
        end
      end
    end
  end
end
