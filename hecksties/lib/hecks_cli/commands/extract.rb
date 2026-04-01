require_relative "../import"

# Hecks CLI — extract command
#
# Auto-detects a project's type (Rails with schema, or models-only)
# and generates a Hecks domain DSL file from the source.
#
#   hecks extract /path/to/rails/app
#   hecks extract /path/to/app --preview --name Blog
#
Hecks::CLI.register_command(:extract, "Extract a domain from an existing project",
  args: %w[PATH],
  options: {
    output:  { type: :string, default: "Bluebook", desc: "Output file path", aliases: "-o" },
    preview: { type: :boolean, default: false, desc: "Preview without writing" },
    name:    { type: :string, desc: "Domain name (default: inferred from directory)" }
  }
) do |path = nil|
  unless path
    puts "Usage: hecks extract /path/to/project"
    puts "       hecks extract /path/to/project --preview --name Blog"
    next
  end

  unless File.directory?(path)
    puts "Error: #{path} is not a directory"
    next
  end

  dsl = Hecks::Import.from_directory(path, domain_name: options[:name])
  puts dsl

  unless options[:preview]
    output = options[:output] || "Bluebook"
    File.write(output, dsl)
    puts "\nWritten to #{output}"
  end
end
