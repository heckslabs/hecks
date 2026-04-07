# Hecks::Generators::RailsGenerator
#
# Runs `rails new` to create a real Rails app, then patches it:
# - Adds hecks + domain gem to Gemfile
# - Adds config/initializers/hecks.rb
# - Modifies the welcome page with Hecks branding
# - Builds the domain gem inside the app
#
#   Hecks::Generators::RailsGenerator.new(domain).generate(output_dir: ".")
#
require "pathname"

module Hecks
  module Generators
    class RailsGenerator < Hecks::Generator

      def initialize(domain)
        @domain = domain
      end

      def generate(output_dir: ".")
        slug = domain_slug(@domain.name)
        @root = File.join(output_dir, "#{slug}_rails")
        @gem_name = domain_gem_name(@domain.name)

        run_rails_new
        patch_gemfile
        add_hecks_initializer
        patch_welcome_page
        @root
      end

      private

      def run_rails_new
        app_name = domain_slug(@domain.name)
        cmd = "rails new #{@root} --name #{app_name} --skip-active-record --skip-test --skip-system-test --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-active-job --skip-active-storage --skip-action-cable --skip-jbuilder --skip-hotwire --minimal --quiet"
        unless system(cmd)
          raise "rails new failed. Is Rails installed? (gem install rails)"
        end
      end

      def patch_gemfile
        gemfile = File.join(@root, "Gemfile")
        content = File.read(gemfile)
        if @domain.source_path
          # The Rails app is a sibling of the domain gem under the same
          # parent (e.g. examples/pizzas_rails alongside examples/pizzas_domain).
          # Hecks root is the same relative distance as from the domain gem.
          hecks_root = File.expand_path("../..", File.dirname(@domain.source_path))
          domain_parent = File.dirname(File.dirname(@domain.source_path))
          app_dir = File.join(File.expand_path(domain_parent), File.basename(@root))
          rel = Pathname.new(hecks_root).relative_path_from(Pathname.new(app_dir))
          content += "\ngem \"hecks\", path: \"#{rel}\"\n"
        else
          content += "\ngem \"hecks\"\n"
        end
        content += "gem \"#{@gem_name}\", path: \"../#{@gem_name}\"\n"
        File.write(gemfile, content)
      end

      def add_hecks_initializer
        write "config/initializers/hecks.rb", <<~RUBY
          require "hecks"
          require "#{@gem_name}"

          Hecks.configure do
            domain "#{@gem_name}"
            adapter :memory
          end
        RUBY
      end

      def patch_welcome_page
        # Copy the Rails welcome page ERB, resolve tags, add Hecks version
        railties = ::Gem.loaded_specs["railties"]
        return unless railties

        source = File.join(railties.full_gem_path, "lib/rails/templates/rails/welcome/index.html.erb")
        return unless File.exist?(source)

        html = File.read(source)

        # Resolve ERB tags to static values
        rails_v = ::Gem.loaded_specs["railties"]&.version&.to_s || "8"
        rack_v = ::Gem.loaded_specs["rack"]&.version&.to_s || ""
        html = html.gsub(/<%= Rails\.version %>/, rails_v)
                   .gsub(/<%= Rack\.release %>/, rack_v)
                   .gsub(/<%= RUBY_DESCRIPTION %>/, RUBY_DESCRIPTION)

        # Add Hecks version after Rack version
        html = html.sub(
          %r{(<li><strong>Rack version:</strong>.*?</li>)},
          "\\1\n    <li class=\"hecks-version\"><a href=\"https://github.com/chrisyoung/hecks\" target=\"_blank\" style=\"text-decoration: none; color: inherit; -webkit-text-fill-color: inherit;\"><strong>Hecks version:</strong> #{Hecks::VERSION}</a></li>"
        )

        # Animated gradient border + Hecks version shimmer
        extra_css = <<~CSS
          @keyframes border-rotate {
            0% { --angle: 0deg; }
            100% { --angle: 360deg; }
          }

          @property --angle {
            syntax: "<angle>";
            initial-value: 0deg;
            inherits: false;
          }

          nav a {
            position: relative;
          }

          nav a:hover {
            background: #D30001 !important;
          }

          nav a::before {
            content: "";
            position: absolute;
            inset: -5px;
            border-radius: 50%;
            background: conic-gradient(from var(--angle), #1a1a4e, #3333cc, #00bfff, #7b2fff, #1a1a4e);
            animation: border-rotate 3s linear infinite;
            z-index: -1;
            mask: radial-gradient(circle, transparent 68%, black 69%);
            -webkit-mask: radial-gradient(circle, transparent 68%, black 69%);
          }

          .hecks-version {
            background: linear-gradient(90deg, #1a1a4e, #3333cc, #00bfff, #7b2fff, #1a1a4e);
            background-size: 200% 100%;
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            animation: hecks-shimmer 3s linear infinite;
            font-weight: bold;
          }

          @keyframes hecks-shimmer {
            0% { background-position: 0% 50%; }
            100% { background-position: 200% 50%; }
          }
        CSS
        html = html.sub("<style type=\"text/css\">", "<style type=\"text/css\">\n    #{extra_css.strip.gsub("\n", "\n    ")}")
        html = html.sub("min-height: 100vh;", "min-height: 100vh;\n      border: 4px solid transparent;\n      border-image: conic-gradient(from var(--angle), #1a1a4e, #3333cc, #00bfff, #7b2fff, #1a1a4e) 1;\n      animation: border-rotate 3s linear infinite;")

        write "public/index.html", html
      end

      def write(path, content)
        full = Hecks::Utils.safe_path!(@root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
      end
    end
  end
end

# Self-register Rails target when loaded
if defined?(Hecks) && Hecks.respond_to?(:register_target)
  Hecks.register_target(:rails) do |domain, output_dir: ".", **|
    valid, errors = Hecks.validate(domain)
    raise Hecks::ValidationError.for_domain(errors) unless valid

    Hecks::Generators::RailsGenerator.new(domain).generate(output_dir: output_dir)
  end
end
