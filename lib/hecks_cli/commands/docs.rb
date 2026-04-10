# Hecks::CLI docs command
#
# Serves a domain as executable documentation in the browser.
# Boots the domain from a .bluebook file, walks the IR, and serves
# interactive panels where you can run commands and watch events.
#
#   hecks docs pizzas.bluebook
#   hecks docs pizzas.bluebook --port 8080
#
Hecks::CLI.handle(:docs) do |inv|
  bluebook_path = inv.args.first
  require "hecks_cli/documentation_server"

  if bluebook_path.nil?
    say "Usage: hecks docs <bluebook-file>", :red
    exit 1
  end

  unless File.exist?(bluebook_path)
    say "Cannot read #{bluebook_path}", :red
    exit 1
  end

  server = Hecks::CLI::DocumentationServer.new(bluebook_path, port: options[:port])
  server.run
end
