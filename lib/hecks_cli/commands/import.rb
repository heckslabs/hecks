Hecks::Chapters.load_aggregates(
  Hecks::Cli::CliInternals,
  base_dir: File.expand_path("..", __dir__)
)

Hecks::CLI.handle(:import) do |inv|
  source = inv.args[0]
  path   = inv.args[1]
  unless source && path
    puts "Usage: hecks import rails /path/to/app"
    puts "       hecks import schema /path/to/schema.rb"
    next
  end

  dsl = case source
        when "rails"
          Hecks::Import.from_rails(path, domain_name: options[:name])
        when "schema"
          Hecks::Import.from_schema(path, domain_name: options[:name] || "MyDomain")
        else
          puts "Unknown source: #{source}. Use 'rails' or 'schema'."
          next
        end

  puts dsl
  unless options[:preview]
    output = options[:output] || "Bluebook"
    File.write(output, dsl)
    puts "\nWritten to #{output}"
  end
end
