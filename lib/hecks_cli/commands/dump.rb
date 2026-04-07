Hecks::CLI.register_command(:dump, "Extract docs from a domain (schema, swagger, rpc, domain, glossary)",
  options: {
    domain:  { type: :string, desc: "Domain gem name or path" },
    version: { type: :string, desc: "Domain version" }
  },
  args: ["TYPE"]
) do |type = nil|
  domain = resolve_domain_option
  next unless domain

  formats = Hecks.dump_formats

  ask_dump_type = lambda do
    say "What would you like to dump?"
    formats.each_with_index do |(name, meta), i|
      say "  #{i + 1}. #{name.to_s.ljust(10)} — #{meta[:desc]}"
    end
    choice_map = formats.keys.each_with_index.to_h { |name, i| [(i + 1).to_s, name.to_s] }
    choice_map[ask("Choice [1-#{formats.size}]:")]
  end

  type ||= ask_dump_type.call
  next unless type

  entry = formats[type.to_sym]
  if entry
    say_proc = method(:say)
    entry[:handler].call(domain, say: say_proc)
  else
    say "Unknown type: #{type}. Use: #{formats.keys.join(', ')}", :red
  end
end
