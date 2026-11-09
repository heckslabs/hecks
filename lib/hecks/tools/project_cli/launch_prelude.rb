module Hecks
  module Tools
    module ProjectCli
      # The lines a launcher runs before it chooses its gems or boots: the resident's probe and the
      # compiled-Ruby cache. They are text, filled into `Templates::LAUNCHER`.
      module LaunchPrelude
        # The lines an executable launcher starts with: a resident for this checkout, when one
        # stands, runs the line in a fork of itself and ends this process with its status.
        # Otherwise the launcher boots as below and starts a resident for the next line. The
        # client uses only the standard library, so nothing of Hecks is loaded before it answers.
        RESIDENT_PROBE = <<~RUBY.freeze

          # A resident for this checkout, when one stands, runs this line and ends it (ADR 0201).
          require "hecks/adapters/driving/resident/client"
          Hecks::Adapters::Driving::Resident::Client.run(__FILE__)
        RUBY

        # The lines that cache the Ruby a launcher compiles and the load path it searches, under the
        # hecks cache directory, when the bootsnap gem is at hand. A launcher without the gem, or
        # whose cache directory does not last between processes (the temp-directory fallback would
        # give every boot a cold cache nobody deletes), boots as it would without them. A resident
        # sets the cache up once for the children it forks, so they skip it.
        COMPILED_RUBY_CACHE = <<~RUBY.freeze

          # The Ruby this boot compiles and the load path it searches are kept between boots.
          begin
            unless defined?(Bootsnap)
              require "bootsnap"
              require "hecks/cache_dir"
              if Hecks::CacheDir.stable?
                Bootsnap.setup(cache_dir: Hecks::CacheDir.path("bootsnap"), development_mode: true,
                               load_path_cache: true, compile_cache_iseq: true, compile_cache_yaml: false)
              end
            end
          rescue ScriptError, StandardError
            nil
          end
        RUBY
      end
    end
  end
end
