# frozen_string_literal: true

module Hecks
  module Adapters
    class DialTurning
      # The checkout's `turned.local.world`: the settings turned from a command, one line a verb
      # under the world it belongs to. It is gitignored and loads after every other local world of
      # the domain (the local files load in name order), so a line here is the value that stands.
      # A turn changes only its own verb's line: {#replace} reads the lines the file holds now, under
      # a lock on the file, so a turn never writes back a copy another turn has since changed.
      class TurnedFile
        NAME = "turned.local.world"
        # The line that opens a world's block, and a verb's line inside one.
        WORLD = /\AHecks\.world "([^"]+)" do/
        VERB = /\A  (\w+) "/
        # A `key: value` pair of a verb's line whose value is a number, a switch or a plain word.
        PAIR = /(\w+): (-?\d+(?:\.\d+)?|true|false|"\w+")(?=,|\s*\z)/
        PLAIN = { "true" => true, "false" => false }.freeze
        HEAD = "# Written by `hecks Dial.turn!` (the board's settings): each line is a setting turned from a\n" \
               "# command, and stands over the same line of any other world file here. Delete a line, or the\n" \
               "# file, to go back to what the other files say. Not committed.\n"

        # @return [String] where the file is
        attr_reader :path

        # @param directory [String] the domain's directory, beside its other world files
        def initialize(directory)
          @path = File.join(directory, NAME)
        end

        # @return [Array<Array(String, String)>] each world and verb the file already holds
        def turned
          return [] unless File.exist?(@path)

          world = nil
          File.readlines(@path).filter_map do |line|
            world = line[WORLD, 1] || world
            [world, line[VERB, 1]] if world && line[VERB, 1]
          end
        end

        # @return [Hash{Array(String, String) => Hash{String => Object}}] each world and verb the
        #   file holds, with the numbers, switches and words its line sets
        def values
          return {} unless File.exist?(@path)

          world = nil
          File.readlines(@path).each_with_object({}) do |line, held|
            world = line[WORLD, 1] || world
            held[[world, line[VERB, 1]]] = pairs(line) if world && line[VERB, 1]
          end
        end

        # @return [Hash{String => Object}] the `key: value` pairs of a verb's line that are
        #   a number, a switch or a word
        def pairs(line) = line.scan(PAIR).to_h { |key, value| [key, PLAIN.fetch(value) { number(value) }] }

        def number(text)
          return text.delete('"') if text.start_with?('"')

          text.include?(".") ? Float(text) : Integer(text, 10)
        end

        # @return [Hash{String => Hash{String => String}}] each world's verb lines as the file holds them
        def lines
          return {} unless File.exist?(@path)

          world = nil
          File.readlines(@path).each_with_object({}) do |line, held|
            world = line[WORLD, 1] || world
            (held[world] ||= {})[line[VERB, 1]] = line.strip if world && line[VERB, 1]
          end
        end

        # Sets one verb's line in the file, keeping every other line as the file holds it now, while
        # holding a lock that every turn takes.
        #
        # @param world [String] the world the verb belongs to
        # @param verb [String] a world verb
        # @param text [String] the line, from {.line}
        # @return [String] the path written
        def replace(world, verb, text)
          locked do
            held = lines
            (held[world] ||= {})[verb] = text
            write(held.transform_values(&:values))
          end
        end

        # Runs the block holding an exclusive lock on the file's lock file; turns queue behind it.
        def locked(&)
          return yield if @locked

          File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
            lock.flock(File::LOCK_EX)
            @locked = true
            yield
          ensure
            @locked = false
          end
        end

        # @param worlds [Hash{String => Array<String>}] each world with its verb lines
        # @return [String] the path written
        def write(worlds)
          put("#{HEAD}#{worlds.map { |world, lines| block(world, lines) }.join("\n")}")
          @path
        end

        # Writes the text beside the file and renames it into place; the temp file is removed
        # when the write fails.
        def put(text)
          temp = "#{@path}.#{Process.pid}.tmp"
          File.write(temp, text)
          File.rename(temp, @path)
        rescue SystemCallError
          File.delete(temp) if temp && File.exist?(temp)
          raise
        end

        # @return [String] one world's block, a line a verb
        def block(world, lines) = "Hecks.world #{world.inspect} do\n#{lines.map { |line| "  #{line}\n" }.join}end\n"

        # @param verb [String] a world verb, such as `work_limit`
        # @param settings [Hash] the verb's settings as the world holds them: `adapter` and its keys
        # @return [String] the verb's line as a world file writes it
        def self.line(verb, settings)
          keys = settings.except(:adapter).map { |key, value| "#{key}: #{value.inspect}" }
          [verb, [settings[:adapter].to_s.inspect, *keys].join(", ")].join(" ")
        end
      end
    end
  end
end
