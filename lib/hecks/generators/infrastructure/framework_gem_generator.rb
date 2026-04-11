Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::GeneratorInternalsParagraph,
  base_dir: File.expand_path("framework_gem_generator", __dir__)
)

module Hecks
  module Generators
    module Infrastructure
      # Hecks::Generators::Infrastructure::FrameworkGemGenerator
      #
      # Generates skeleton files for framework gems (DSL builders, module mixins,
      # IR structures, boot modules, extensions) from a chapter's Domain IR.
      # Uses namespace, superclass, mixins, and method_name
      # from the IR to produce skeletons that match actual gem structure.
      #
      #   domain = Hecks::Chapters.definition_from_bluebook("hecksagon")
      #   gen = FrameworkGemGenerator.new(domain, gem_root: "hecksagon")
      #   gen.generate(output_dir: Dir.mktmpdir)
      #
      class FrameworkGemGenerator
        include Hecks::Conventions::NamingHelpers

        def initialize(domain, gem_root:)
          @domain   = domain
          @gem_root = File.expand_path(gem_root)
          @locator  = FileLocator.new(@gem_root)
        end

        def generate(output_dir:)
          files = {}

          @domain.aggregates.each do |agg|
            rel_path = @locator.locate(agg.name)
            next unless rel_path

            actual_path = File.join(@gem_root, "lib", rel_path)
            skeleton = SkeletonGenerator.new(agg, actual_path).generate
            files[rel_path] = skeleton

            out_path = File.join(output_dir, rel_path)
            FileUtils.mkdir_p(File.dirname(out_path))
            File.write(out_path, skeleton)
          end

          # Generate entry point skeletons
          @domain.entry_points.each do |ep_name|
            rel_path = "#{ep_name}.rb"
            skeleton = entry_point_skeleton(ep_name)
            files[rel_path] = skeleton

            out_path = File.join(output_dir, rel_path)
            FileUtils.mkdir_p(File.dirname(out_path))
            File.write(out_path, skeleton)
          end

          files
        end

        def located_aggregates
          @domain.aggregates.filter_map do |agg|
            path = @locator.locate(agg.name)
            { aggregate: agg.name, path: path } if path
          end
        end

        def unlocated_aggregates
          @domain.aggregates.filter_map do |agg|
            agg.name unless @locator.locate(agg.name)
          end
        end

        private

        def entry_point_skeleton(name)
          mod = Hecks::Utils.sanitize_constant(name)
          lines = []
          lines << "# #{mod}"
          lines << "#"
          lines << "# Entry point for #{name}. Sets up autoloads."
          lines << "#"
          lines << "module #{mod}"
          lines << "end"
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
