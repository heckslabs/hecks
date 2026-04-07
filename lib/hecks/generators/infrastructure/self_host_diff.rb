require "tmpdir"
require "fileutils"

module Hecks
  module Generators
    module Infrastructure
      # Hecks::Generators::Infrastructure::SelfHostDiff
      #
      # Compares what generators would produce from a chapter's Domain IR
      # against the actual code in the gem's lib/ directory.
      # Classifies every file as :match, :partial, :uncovered, or :extra.
      #
      # Two modes:
      #   :domain    — uses DomainGemGenerator (user domain code patterns)
      #   :framework — uses FrameworkGemGenerator (framework code skeletons)
      #
      #   diff = SelfHostDiff.new(domain, gem_root: "hecksagon", mode: :framework)
      #   diff.summary[:entries].each { |e| puts "#{e.status}  #{e.path}" }
      #
      class SelfHostDiff
        # Hecks::Generators::Infrastructure::SelfHostDiff::Entry
        #
        # Value object representing a single diff entry with path, status, and detail.
        #
        Entry = Struct.new(:path, :status, :detail, keyword_init: true)

        def initialize(domain, gem_root:, mode: :domain)
          @domain   = domain
          @gem_root = File.expand_path(gem_root)
          @mode     = mode
        end

        def call
          generated = generate_in_memory
          actual    = scan_actual
          entries   = []

          all_paths = (generated.keys | actual.keys).sort

          all_paths.each do |path|
            gen = generated[path]
            act = actual[path]
            entries << classify(path, gen, act)
          end

          entries
        end

        def summary
          results = call
          grouped = results.group_by(&:status)
          {
            total:     results.size,
            match:     (grouped[:match]     || []).size,
            partial:   (grouped[:partial]   || []).size,
            uncovered: (grouped[:uncovered] || []).size,
            extra:     (grouped[:extra]     || []).size,
            entries:   results
          }
        end

        private

        def generate_in_memory
          @mode == :framework ? generate_framework : generate_domain
        end

        def generate_domain
          files = {}
          Dir.mktmpdir("hecks_self_diff") do |tmpdir|
            DomainGemGenerator.new(@domain, output_dir: tmpdir).generate
            gem_name = @domain.gem_name
            gen_root = File.join(tmpdir, gem_name, "lib")
            Dir.glob(File.join(gen_root, "**", "*.rb")).each do |abs|
              rel = abs.sub("#{gen_root}/", "")
              files[rel] = File.read(abs)
            end
          end
          files
        end

        def generate_framework
          Dir.mktmpdir("hecks_fw_diff") do |tmpdir|
            gen = FrameworkGemGenerator.new(@domain, gem_root: @gem_root)
            gen.generate(output_dir: tmpdir)
          end
        end

        def scan_actual
          files = {}
          lib_root = File.join(@gem_root, "lib")
          return files unless Dir.exist?(lib_root)

          Dir.glob(File.join(lib_root, "**", "*.rb")).each do |abs|
            rel = abs.sub("#{lib_root}/", "")
            # Skip chapter definitions in framework mode
            next if @mode == :framework && rel.include?("chapters/")
            files[rel] = File.read(abs)
          end
          files
        end

        def classify(path, generated, actual)
          if generated && actual
            if normalize(generated) == normalize(actual)
              Entry.new(path: path, status: :match, detail: nil)
            else
              Entry.new(path: path, status: :partial,
                        detail: diff_summary(generated, actual))
            end
          elsif generated && !actual
            Entry.new(path: path, status: :extra,
                      detail: "generator produces this but gem lacks it")
          else
            Entry.new(path: path, status: :uncovered,
                      detail: "exists in gem but no generator produces it")
          end
        end

        def normalize(src)
          src.gsub(/\s+/, " ").strip
        end

        def diff_summary(generated, actual)
          gen_lines = generated.lines.map(&:rstrip)
          act_lines = actual.lines.map(&:rstrip)
          shared = (gen_lines & act_lines).size
          total  = [gen_lines.size, act_lines.size].max
          pct    = total.zero? ? 0 : (shared * 100.0 / total).round(1)
          "#{pct}% line overlap (gen: #{gen_lines.size} lines, actual: #{act_lines.size} lines)"
        end
      end
    end
  end
end
