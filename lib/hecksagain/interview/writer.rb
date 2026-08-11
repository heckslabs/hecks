require "digest"
require "fileutils"
require "tmpdir"
require_relative "source"
require_relative "../runtime/registry"
require_relative "../bluebook/assembly"

module Hecksagain
  module Interview
    # WRITES A WHOLE, BOOTABLE DOMAIN DIRECTORY — the moment "save it"
    # stops meaning "durable interview records" and starts meaning "a
    # real bluebook/ a real app can point adapters at":
    #
    #   <dir>/bluebook/<name>.bluebook   rendered from the reconstruction
    #   <dir>/bluebook/<name>.hecksagon  every aggregate bound to Memory
    #   <dir>/bluebook/<name>.world      a realm, nothing else — Memory
    #                                    needs no settings; swap the
    #                                    binding to something durable
    #                                    when it's real, and an era
    #                                    mints from that moment, not
    #                                    before
    #
    # WRITES ONLY WHAT IT OWNS. A `.bluebook` this class did not create
    # carries comments, ordering, and constructs the reconstructed IR
    # does not hold at all — round_trip_spec.rb pins the exact set —
    # and a whole-file re-render would silently DELETE every one. So the
    # first write stamps a digest; every later write to the SAME path
    # checks the file still matches it and refuses otherwise, saying
    # plainly that something else changed it rather than overwriting in
    # silence.
    module Writer
      Drifted = Class.new(StandardError)
      # The render loaded back and produced a DIFFERENT `to_h` than the
      # declaration it was rendered from — the one failure mode that
      # must never reach disk. `spec/interview/source_render_gate_spec.rb`
      # is what keeps this from firing on real corpus shapes; a NEW
      # construct the renderer does not yet know is exactly what would
      # trip it first.
      Unfaithful = Class.new(StandardError)

      module_function

      def save!(declaration, to:)
        dir = File.join(to, "bluebook")
        FileUtils.mkdir_p(dir)

        bluebook_path = File.join(dir, "#{storage_name(declaration[:name])}.bluebook")
        write_bluebook!(bluebook_path, declaration)
        File.write(File.join(dir, "#{storage_name(declaration[:name])}.hecksagon"), hecksagon_text(declaration))
        File.write(File.join(dir, "#{storage_name(declaration[:name])}.world"), world_text(declaration))
        bluebook_path
      end

      def write_bluebook!(path, declaration)
        text = Source.render(declaration)
        verify!(text, declaration)

        if File.exist?(path)
          current = Digest::SHA256.hexdigest(File.read(path))
          held    = stamp_of(path)
          raise Drifted, "#{path} changed since this tool last wrote it — " \
                         "re-run against its current content, or move it aside first" if held && held != current
        end

        File.write(path, text)
        File.write("#{path}.digest", Digest::SHA256.hexdigest(text))
      end

      # RENDER, LOAD, COMPARE — the same discipline
      # `source_render_gate_spec.rb` holds the whole corpus to, run here
      # on every real write too, not only in the suite. A renderer gap
      # the corpus never happened to exercise fails LOUDLY on save,
      # before anything reaches disk, rather than writing a file that
      # quietly means something else.
      def verify!(text, declaration)
        Dir.mktmpdir do |dir|
          path = File.join(dir, "verify.bluebook")
          File.write(path, text)
          registry = Runtime::Registry.new
          Hecksagain.with_registry(registry) do
            Kernel.load(File.expand_path("../ports/persistence.port", __dir__))
            Kernel.load(File.expand_path("../ports/extraction.port", __dir__))
            Kernel.load(File.expand_path("../adapters/driven/memory.adapter", __dir__))
            Kernel.load(File.expand_path("../adapters/driven/prism.adapter", __dir__))
            Kernel.load(path)
          end
          reloaded = registry.bluebook(declaration[:name])
          expected = Bluebook::Assembly.call(declaration)
          raise Unfaithful, "the rendered text does not reload to what it was rendered from" \
                             unless reloaded.to_h == expected.to_h
        end
      end

      def stamp_of(path)
        return nil unless File.exist?("#{path}.digest")

        File.read("#{path}.digest").strip
      end

      def hecksagon_text(declaration)
        name = declaration[:name]
        lines = ["Hecks.hecksagon #{name.inspect} do"]
        declaration[:aggregates].each { |a| lines << "  #{name}::#{a[:name]}.persisted_by(\"Memory\")" }
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      def world_text(declaration)
        <<~WORLD
          Hecks.world #{declaration[:name].inspect} do
            realm "Development"
          end
        WORLD
      end

      def storage_name(name) = Naming.snake(name)
    end
  end
end
