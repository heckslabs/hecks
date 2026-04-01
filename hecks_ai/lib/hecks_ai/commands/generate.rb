# Hecks::AI::Commands::Generate
#
# CLI command: generate a Bluebook DSL file from a natural language description.
# Reads ANTHROPIC_API_KEY from ENV, calls the LLM, builds via Workshop, saves DSL.
#
#   hecks generate "banking system with accounts, loans, and transfers"
#   hecks generate "e-commerce platform" --output MyShopBluebook --dry-run
#
Hecks::CLI.register_command(:generate, "Generate Bluebook DSL from a natural language description",
  args: ["DESCRIPTION"],
  options: {
    model:   { type: :string,  desc: "Anthropic model (default: claude-opus-4-5)" },
    output:  { type: :string,  desc: "Output file path (default: <DomainName>Bluebook)" },
    dry_run: { type: :boolean, desc: "Print DSL without writing to disk", aliases: ["--dry-run"] }
  }
) do |description|
  require "hecks_ai"
  require_relative "../type_resolver"
  require_relative "../llm_client"
  require_relative "../domain_builder"
  require_relative "../prompts/domain_generation"

  unless description && !description.strip.empty?
    say "Usage: hecks generate \"describe your domain here\"", :red
    next
  end

  api_key = ENV["ANTHROPIC_API_KEY"]
  unless api_key && !api_key.strip.empty?
    say "Error: ANTHROPIC_API_KEY environment variable is not set", :red
    next
  end

  say "Generating domain from: #{description}"

  client_opts = { api_key: api_key }
  client_opts[:model] = options[:model] if options[:model]

  domain_json = Hecks::AI::LlmClient.new(**client_opts).generate_domain(description)
  workshop    = Hecks::AI::DomainBuilder.new(domain_json).build
  dsl         = workshop.to_dsl

  if options[:dry_run]
    say "\n#{dsl}", :cyan
    say "\nDry run — no file written", :yellow
  else
    domain_name = domain_json[:domain_name] || domain_json["domain_name"]
    output_path = options[:output] || "#{domain_name}Bluebook"
    File.write(output_path, dsl)
    say "Wrote #{output_path}", :green
    say "\n#{dsl}"
  end
rescue => e
  say "Error: #{e.message}", :red
end
