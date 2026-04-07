require "fileutils"

module HecksStatic
  # HecksStatic::RuntimeWriter
  #
  # Copies runtime template files into the generated gem's runtime/
  # directory, replacing the __DOMAIN_MODULE__ placeholder with the
  # actual domain module name. These files give the generated gem a
  # self-contained runtime with zero dependency on the hecks gem.
  #
  #   RuntimeWriter.new("PizzasDomain").write(root, "pizzas_domain")
  #
  class RuntimeWriter
    TEMPLATES = %w[
      errors
      event_bus
      operators
      specification
      model
      command
      command_bus
      query_builder
      query
    ].freeze

    def initialize(domain_module)
      @domain_module = domain_module
      @template_dir = File.expand_path("../templates", __dir__)
    end

    def write(gem_root, gem_name)
      runtime_dir = File.join(gem_root, "lib", gem_name, "runtime")
      FileUtils.mkdir_p(runtime_dir)

      TEMPLATES.each do |name|
        source = File.read(File.join(@template_dir, "#{name}.rb"))
        output = source.gsub("__DOMAIN_MODULE__", @domain_module)
        File.write(File.join(runtime_dir, "#{name}.rb"), output)
      end
    end
  end
end
