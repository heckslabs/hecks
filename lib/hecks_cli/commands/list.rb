Hecks::CLI.register_command(:list, "List installed Hecks domain gems") do
  domains = find_installed_domains
  if domains.empty?
    say "No Hecks domains installed.", :yellow
  else
    say "Installed Hecks domains:", :green
    domains.each do |name, versions|
      if versions.size == 1
        say "  #{name} (v#{versions.first})"
      else
        say "  #{name} (#{versions.map { |v| "v#{v}" }.join(", ")})"
      end
    end
  end
end
