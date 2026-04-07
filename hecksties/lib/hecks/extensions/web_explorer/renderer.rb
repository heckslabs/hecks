# Hecks::WebExplorer::Renderer
#
# Renders ERB templates with a data binding. Handles layout wrapping
# and HTML escaping. Used by both the dynamic runtime server and the
# static generated server.
#
#   renderer = Renderer.new(views_dir)
#   html = renderer.render(:index, layout_data.merge(items: pizzas))
#
require "erb"

module Hecks
  module WebExplorer
    # Hecks::WebExplorer::Renderer
    #
    # Renders ERB templates with a data binding for web explorer views, handling layout wrapping and escaping.
    #
    class Renderer
      def initialize(views_dir)
        @views_dir = views_dir
        @cache = {}
      end

      def render(template_name, locals = {})
        content = render_template(template_name, locals)
        if locals[:skip_layout]
          content
        else
          render_template(:layout, locals) { content }
        end
      end

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      private

      def render_template(name, locals = {}, &block)
        path = File.join(@views_dir, "#{name}.erb")
        template = @cache[path] ||= File.read(path)
        b = TemplateBinding.new(locals, self, &block)
        ERB.new(template, trim_mode: "-").result(b.get_binding)
      end
    end

    # Provides a clean binding for ERB templates. Locals become methods,
    # yield returns the content block (for layout).
    class TemplateBinding
      def initialize(locals, renderer, &block)
        @_renderer = renderer
        @_block = block
        locals.each do |key, value|
          define_singleton_method(key) { value } unless key == :skip_layout
        end
      end

      def h(text)
        @_renderer.h(text)
      end

      def content
        @_block&.call || ""
      end

      def get_binding
        binding
      end
    end
  end
end
