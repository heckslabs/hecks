require "English"
require "tempfile"
require "hecks/adapters/driving/resident/outcome"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The forked child of a resident: it takes the caller's terminal, directory and
        # environment and runs the launcher script itself, so the line is handled by the
        # launcher's own top level and nothing about it is written twice. The one difference is
        # that `Hecks.describe` answers from what the resident already loaded.
        class Worker
          # Answers `Hecks.describe` from the resident's cache; a domain it lacks is loaded by the
          # child as a cold launcher would, and named to the resident so the next line finds it.
          module Describing
            class << self
              attr_accessor :cache, :notes
            end

            def describe(path, **options)
              environment = ENV.fetch("HECKS_ENVIRONMENT", nil)
              held = options.empty? ? Describing.cache.fetch(path, environment) : nil
              return replay(held, path, environment) if held

              Describing.notes.puts("D\t#{File.expand_path(path)}\t#{environment}") if options.empty?
              super
            end

            private

            # Hands out the loaded domain, which prints what loading it printed the first time
            # this line asks for its registry, as a cold launcher would: a line answered without
            # the registry (a help text already remembered) prints nothing, there or here.
            def replay(held, path, environment)
              text = Describing.cache.printed(path, environment)
              return held if text.empty?

              loaded = held.method(:registry)
              printed = false
              held.define_singleton_method(:registry) do
                printed ||= $stderr.print(text) || true
                loaded.call
              end
              held
            end
          end

          # Ends a child once every exit handler has run. Ruby would now free the whole heap it
          # shares with the resident, which costs more than the line did; the operating system
          # does it for nothing. What that teardown would have done that matters is done here:
          # output flushed, an uncaught error reported, and the temporary files this line made
          # removed.
          def self.leave
            error = $ERROR_INFO
            warn(error.full_message) if error && !error.is_a?(SystemExit)
            ObjectSpace.each_object(Tempfile, &:close!)
            $stdout.flush
            $stderr.flush
            Process.exit!(status_of(error))
          end

          # @return [Integer] the exit status the error, or the lack of one, stands for
          def self.status_of(error)
            return error.status if error.is_a?(SystemExit)

            error ? 1 : 0
          end

          # @param request [Hash] `argv`, `cwd`, `env` and `script` as the client sent them
          # @param streams [Array<IO>] the caller's standard input, output and error
          # @param cache [DescribedCache] what the resident has loaded
          # @param notes [IO] where the child names a domain the cache lacked
          def initialize(request, streams, cache, notes)
            @request = request
            @streams = streams
            @cache = cache
            @notes = notes
          end

          # Runs the line and ends the child with its status. It first names itself `CHILD`, so the
          # launcher it loads does not look for a resident again.
          def run
            Resident.const_set(:CHILD, true)
            take_over
            Describing.cache = @cache
            Describing.notes = @notes
            Hecks.singleton_class.prepend(Describing)
            Object.send(:remove_const, :HECKS_LAUNCHED_AT) if Object.const_defined?(:HECKS_LAUNCHED_AT)
            report_loads
            load @request[:script]
            exit(0)
          end

          private

          # At exit, names the Ruby files this line loaded that the resident had not, so the
          # resident loads them.
          def report_loads
            before = $LOADED_FEATURES.size
            notes = @notes
            at_exit { $LOADED_FEATURES[before..].each { |path| notes.puts("F\t#{path}") } }
          end

          def take_over
            $stdin.reopen(@streams[0])
            $stdout.reopen(@streams[1])
            $stderr.reopen(@streams[2])
            Dir.chdir(@request[:cwd])
            ENV.replace(@request[:env])
            Outcome.note(Outcome::SERVED)
            ARGV.replace(@request[:argv])
            $PROGRAM_NAME = @request[:script]
            %w[INT TERM HUP].each { |signal| Signal.trap(signal, "DEFAULT") }
          end
        end
      end
    end
  end
end
