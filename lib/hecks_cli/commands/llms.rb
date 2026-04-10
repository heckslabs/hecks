Hecks::CLI.handle(:llms) do |inv|
  domain = resolve_domain_option
  next unless domain

  puts Hecks::LlmsGenerator.new(domain).generate
end
