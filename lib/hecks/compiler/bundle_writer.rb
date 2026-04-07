# Hecks::Compiler::BundleWriter
#
# Takes an ordered list of source files and concatenates them into a
# single self-contained Ruby script. Strips all require/require_relative
# calls, neutralizes chapter loading, and guards external class
# inheritance with defined?() checks.
#
#   Hecks::Compiler::BundleWriter.write(files, output: "hecks_v0")
#
module Hecks
  module Compiler
    module BundleWriter
      SHEBANG = "#!/usr/bin/env ruby"
      BANNER  = <<~RUBY
        #
        # Hecks v0 — self-compiled binary
        # Generated: %<timestamp>s
        # Files: %<count>d
        #
        # All framework source concatenated in load order.
        #
      RUBY

      # Writes the bundled script to the output path.
      def self.write(files, output:, lib_root:)
        last_registry_idx = find_last_registry_index(files)

        File.open(output, "w") do |f|
          write_header(f, files.size)
          write_stdlib_requires(f)
          ForwardDeclarations.write(f)
          write_loaded_features(f, files)
          files.each_with_index do |path, idx|
            write_file(f, path, lib_root)
            if idx == last_registry_idx
              ForwardDeclarations.write_registry_extends(f)
            end
          end
          write_entrypoint(f)
        end
        File.chmod(0o755, output)
        output
      end

      # Finds the index of the last registries/ file so we inject
      # extends after all registry modules are defined.
      def self.find_last_registry_index(files)
        last = nil
        files.each_with_index do |path, idx|
          last = idx if path.include?("/registries/")
        end
        last
      end

      def self.write_header(io, count)
        io.puts SHEBANG
        io.puts format(BANNER, timestamp: Time.now.strftime("%Y-%m-%dT%H:%M:%S%z"), count: count)
      end

      def self.write_stdlib_requires(io)
        io.puts "require \"json\""
        io.puts "require \"date\""
        io.puts "require \"ostruct\""
        io.puts "require \"fileutils\""
        io.puts "require \"tmpdir\""
        io.puts "require \"set\""
        io.puts "$HECKS_V0 = true"
        io.puts ""
      end

      def self.write_loaded_features(io, files)
        io.puts "# Remove hecks gem paths from $LOAD_PATH to prevent"
        io.puts "# double-loading from the original source on disk."
        io.puts "$LOAD_PATH.reject! { |p| p.include?(\"hecks\") }"
        io.puts ""
        io.puts "# Pre-register bundled files so require() skips them."
        files.each do |f|
          io.puts "$LOADED_FEATURES << #{f.inspect}"
          rel = f.sub(%r{.*/lib/}, "")
          io.puts "$LOADED_FEATURES << #{rel.inspect}" if rel != f
        end
        io.puts ""
      end

      def self.write_file(io, path, lib_root)
        rel = path.sub("#{lib_root}/", "")
        io.puts "# --- #{rel} ---"
        content = File.read(path)
        io.puts SourceTransformer.transform(content)
        io.puts
      end

      def self.write_entrypoint(io)
        io.puts <<~'RUBY'
          # --- Hecks v0 entrypoint ---
          if __FILE__ == $0
            command = ARGV.shift
            case command
            when "boot"
              path = ARGV.shift || "."
              app = Hecks.boot(File.expand_path(path))
              puts "Hecks v0: booted #{app.domain.name} from #{path}"
            when "version"
              puts "Hecks v0 (self-compiled)"
              puts "Version: #{Hecks::VERSION}"
            when "self-test"
              puts "Hecks v0 self-test:"
              puts "  Version: #{Hecks::VERSION}"
              puts "  Modules: #{Hecks.constants.size}"
              puts "  Targets: #{Hecks.target_registry.keys.join(', ')}"
              puts "  Status: OK"
            else
              puts "Hecks v0 -- self-compiled domain compiler"
              puts ""
              puts "Usage:"
              puts "  hecks_v0 boot [path]     Boot a domain from path"
              puts "  hecks_v0 version         Show version info"
              puts "  hecks_v0 self-test       Run self-consistency check"
            end
          end
        RUBY
      end

      private_class_method :write_header, :write_stdlib_requires,
                           :write_loaded_features, :write_file,
                           :write_entrypoint, :find_last_registry_index
    end
  end
end
