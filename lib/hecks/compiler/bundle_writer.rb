# Hecks::Compiler::BundleWriter
#
# Takes an ordered list of source files and concatenates them into a
# single self-contained Ruby script. Strips require_relative calls,
# neutralizes chapter loading, and guards require via $LOADED_FEATURES.
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
        File.open(output, "w") do |f|
          write_header(f, files.size)
          write_stdlib_requires(f)
          ForwardDeclarations.write(f)
          write_loaded_features(f, files)
          registry_injected = false
          files.each do |path|
            write_file(f, path, lib_root)
            if !registry_injected && path.include?("grammar_registry")
              ForwardDeclarations.write_registry_extends(f)
              registry_injected = true
            end
          end
          write_entrypoint(f)
        end
        File.chmod(0o755, output)
        output
      end

      def self.write_header(io, count)
        io.puts SHEBANG
        io.puts format(BANNER, timestamp: Time.now.iso8601, count: count)
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
        io.puts "# Add both absolute and lib-relative paths."
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
        cleaned = strip_bundled_lines(content)
        io.puts cleaned
        io.puts
      end

      # Comments out require_relative, internal require, chapter loading,
      # and Dir[] loading calls that reference bundled code.
      def self.strip_bundled_lines(source)
        lines = source.lines
        result = []
        skip_depth = 0

        lines.each do |line|
          stripped = line.strip
          if skip_depth > 0
            skip_depth += line.count("(") - line.count(")")
            result << "# [v0] #{line.chomp}\n"
            skip_depth = 0 if skip_depth <= 0
          elsif should_strip?(stripped)
            result << "# [v0] #{stripped}\n"
            if multiline_call?(stripped)
              skip_depth = stripped.count("(") - stripped.count(")")
            end
          else
            result << line
          end
        end
        result.join
      end

      def self.should_strip?(line)
        line.match?(/\Arequire_relative\s/) ||
          hecks_require?(line) ||
          chapter_load?(line) ||
          dir_glob_require?(line)
      end

      def self.hecks_require?(line)
        line.match?(/\Arequire\s+["'](?:hecks|bluebook|hecksagon|hecks_cli|hecks_persist|hecks_mongodb|hecksul|heckscode|hecks_serve|hecks_multidomain|hecks_targets|go_hecks|node_hecks|hecks_ai|active_hecks|hecks_live|hecks_static)/)
      end

      def self.chapter_load?(line)
        line.match?(/(?:Hecks::)?Chapters\.(load_chapter|load_aggregates|require_paragraphs)\b/)
      end

      def self.dir_glob_require?(line)
        line.match?(/\ADir\[.*\].*\.each\s*\{.*require/)
      end

      def self.multiline_call?(line)
        line.include?("(") && line.count("(") > line.count(")")
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
                           :strip_bundled_lines, :should_strip?,
                           :hecks_require?, :chapter_load?,
                           :dir_glob_require?, :multiline_call?,
                           :write_entrypoint
    end
  end
end
