require "fileutils"
require "open3"

# A scratch domain, Depot, that holds the Hecks push train's own declarations: the `SendTrain`
# aggregate and the push policies, cut from `deliver.bluebook`, and the Train, Alerts and Launcher
# ports, cut from `hecks.hecksagon`. It is split across files the way the Hecks domain is, a
# top-level file and a `deliver` module folder, and persisted by PostgresEra on a scratch database.
module PushTrainDepot
  HECKS = File.expand_path("../../lib/hecks/hecks", __dir__)

  # The push policies the depot declares, in the order a boarding reaches them.
  POLICIES = %w[CarryWhenBoarded RecordThePush RecordTheRide RecordTheQueuedBoarding RecordTheRefusedPush
                ObserveWhenAsked RecordTheMerge KeepTheLauncherCurrent AnnounceWhenPushed].freeze

  # The ports the push train asks.
  PORTS = %w[Train Alerts Launcher].freeze

  # The adapters the depot loads, by the files the Hecks domain declares them in.
  ADAPTERS = %w[git_train desktop_alert git_launcher].freeze

  # The lines of a `deliver.bluebook` block, from its opening line to the `end` at its indent.
  def self.block(lines, opening)
    start = lines.index { |line| line.rstrip == opening } or raise "no #{opening.strip} in the Hecks domain"
    indent = opening[/\A */]
    finish = ((start + 1)...lines.size).find { |index| lines[index].rstrip == "#{indent}end" }
    lines[start..finish].join
  end

  def self.deliver_lines = File.readlines(File.join(HECKS, "deliver", "deliver.bluebook"))

  def self.hecksagon_lines = File.readlines(File.join(HECKS, "hecks.hecksagon"))

  # @param extra [String] a line added to the aggregate, to give the depot another shape
  # @return [String] the deliver module folder's bluebook
  def self.deliver_source(extra: "")
    aggregate = block(deliver_lines, %(    aggregate "SendTrain" do))
    aggregate = aggregate.sub("      identified_by :run\n", "#{extra}      identified_by :run\n")
    policies = POLICIES.map { |name| block(deliver_lines, %(    policy "#{name}" do)) }
    %(Hecks.bluebook "Depot" do\n  domain_module "Deliver" do\n#{aggregate}\n#{policies.join("\n")}  end\nend\n)
  end

  # @return [String] the hecksagon: persisted by PostgresEra, governed (its commands declare roles),
  #   with the push train's ports
  def self.hecksagon_source
    ports = PORTS.map { |name| block(hecksagon_lines, %(  Hecks::SendTrain.port "#{name}" do)) }
    head = %(Hecks.hecksagon "Depot" do\n  attaches "Governance"\n  persisted_by "PostgresEra"\n\n)
    %(#{head}#{ports.join("\n").gsub("Hecks::", "Depot::")}end\n\nHecks.hecksagon "Governance" do\n  persisted_by "Memory"\nend\n)
  end

  # @param url [String] the database the depot's eras and records are kept in
  # @param disposable [Boolean] declare the ledger disposable, so a boot never refuses; else the
  #   world mints eras
  # @return [String] the world naming the scratch database
  def self.world_source(url, disposable: false)
    setting = disposable ? "disposable_ledger true" : "mint_eras true"
    %(Hecks.world "Depot" do\n  persisted_by("PostgresEra") do\n    database "#{url}"\n    #{setting}\n  end\nend\n)
  end

  # Writes the depot into `dir` with the aggregate shaped by `shape` (see `deliver_source`).
  def self.write!(dir, url, disposable: false, **shape)
    FileUtils.mkdir_p(File.join(dir, "deliver"))
    FileUtils.mkdir_p(File.join(dir, "translations"))
    File.write(File.join(dir, "depot.bluebook"), %(Hecks.bluebook "Depot" do\n  vision "Push finished work."\nend\n))
    File.write(File.join(dir, "deliver", "deliver.bluebook"), deliver_source(**shape))
    write_wiring!(dir, url, disposable)
  end

  # The hecksagon, the world and the adapters the depot is wired by.
  def self.write_wiring!(dir, url, disposable)
    File.write(File.join(dir, "depot.hecksagon"), hecksagon_source)
    File.write(File.join(dir, "depot.world"), world_source(url, disposable: disposable))
    ADAPTERS.each { |name| FileUtils.cp(File.join(HECKS, "adapters", "#{name}.adapter"), dir) }
  end

  # Holds era 1 from the depot as it stands in `dir`: its whole source and its storage shape.
  def self.hold!(dir, url)
    bluebook = Hecks.describe(dir).registry.bluebooks["Depot"]
    db = Hecks::Adapters::PostgresEra.connect_for("Depot", { database: url })
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Depot")
    lineage.ensure_base!
    lineage.hold_first!(Hecks::Runtime::RevisionCheck.source_text_for(bluebook, dir),
                        projection: Hecks::Runtime::StorageShape.project(bluebook))
    lineage.provision_first_era!(bluebook.aggregates)
  ensure
    db&.close
  end

  # A local repository with a bare remote and one commit on `main` that the remote lacks.
  def self.checkout!(scratch)
    git(scratch, "init", "-q", "--bare", "-b", "main", "origin.git")
    git(scratch, "clone", "-q", "origin.git", "work")
    work = File.join(scratch, "work")
    git(work, "checkout", "-q", "-b", "main")
    git(work, "commit", "-q", "--allow-empty", "-m", "first")
    git(work, "push", "-q", "origin", "main")
    git(work, "commit", "-q", "--allow-empty", "-m", "boarded")
    work
  end

  IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
               "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze

  def self.git(dir, *args)
    out, err, status = Open3.capture3(IDENTITY, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end
end
