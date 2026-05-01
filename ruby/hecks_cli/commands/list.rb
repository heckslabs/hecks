Hecks::CLI.handle(:list) do |inv|
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
