Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Cli::CliInternals,
  base_dir: __dir__
)

Hecks::CLI.register_command(:version_log, "List all tagged domain version snapshots",
  options: {
    domain: { type: :string, desc: "Domain gem name or path" }
  }
) do
  entries = Hecks::DomainVersioning.log(base_dir: Dir.pwd)

  if entries.empty?
    say "No versions tagged yet. Run `hecks version_tag <version>` to tag one.", :yellow
    next
  end

  lines = Hecks::CLI::VersionLogFormatter.format(entries)
  lines.each { |line| say line }
end
