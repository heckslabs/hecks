# Hecks::Capabilities::Tailwind
#
# CSS compilation capability using tailwindcss-ruby.
# Spawns a watcher process configured from world.hec.
# No-op if tailwindcss binary is not available.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :tailwind
#   end
#
#   Hecks.world "MyApp" do
#     tailwind do
#       input "assets/css/app.css"
#       output "assets/css/tailwind.css"
#       content "views/**/*.html", "assets/js/**/*.js"
#     end
#   end
#
require_relative "dsl"

module Hecks
  module Capabilities
    # Hecks::Capabilities::Tailwind
    #
    # Spawns tailwindcss --watch from world config. No-op if not installed.
    #
    module Tailwind
      def self.apply(runtime)
        config = world_config
        base = runtime.respond_to?(:root) ? runtime.root : Dir.pwd

        input = File.expand_path(config[:input] || "assets/css/app.css", base)
        output = File.expand_path(config[:output] || "assets/css/tailwind.css", base)
        content_dirs = Array(config[:content] || [
          File.join(base, "views", "**", "*.html"),
          File.join(base, "assets", "js", "**", "*.js")
        ])

        return unless File.exist?(input)
        return unless tailwind_available?

        content_arg = content_dirs.map { |d| File.expand_path(d, base) }.join(",")
        pid = Process.spawn("tailwindcss", "-i", input, "-o", output,
                            "--content", content_arg, "--minify", "--watch",
                            out: File::NULL, err: File::NULL)
        Process.detach(pid)
        $stderr.puts "[Tailwind] Watching #{File.basename(input)} → #{File.basename(output)}"
      end

      def self.tailwind_available?
        system("which tailwindcss > /dev/null 2>&1")
      end
      private_class_method :tailwind_available?

      def self.world_config
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
        world ? world.config_for(:tailwind) : {}
      end
      private_class_method :world_config
    end
  end
end

Hecks.capability :tailwind do
  description "CSS compilation via tailwindcss --watch"
  direction :driven
  config do
    input "assets/css/app.css", desc: "Tailwind input CSS"
    output "assets/css/tailwind.css", desc: "Compiled output CSS"
    content ["views/**/*.html", "assets/js/**/*.js"], desc: "Content paths to scan"
  end
  on_apply do |runtime|
    Hecks::Capabilities::Tailwind.apply(runtime)
  end
end
