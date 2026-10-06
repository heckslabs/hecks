require "tmpdir"
require "fileutils"

# Which `.world` file `hecks deploy project <dir>` reads when none is named after the directory:
# the QA ledger (`qa/`) holds `quality_control.world` beside `governance.world`, attaches the
# QualityControl chapter from the gem, and has no bluebook of its own.
RSpec.describe "hecks deploy project world lookup", :io do
  let(:recipe) { Hecks::Tools.fetch("project_deploy") }

  def root = File.expand_path("..", __dir__)

  def write_domain(dir, worlds:, hecksagon: nil)
    bluebook_dir = File.join(dir, "ledger", "bluebook")
    FileUtils.mkdir_p(bluebook_dir)
    worlds.each { |name| File.write(File.join(bluebook_dir, "#{name}.world"), "Hecks.world \"#{name}\" do\nend\n") }
    File.write(File.join(bluebook_dir, "ledger.hecksagon"), hecksagon) if hecksagon
    File.join(dir, "ledger")
  end

  it "resolves the QA ledger's quality_control.world" do
    expect(recipe.world_file_for(File.join(root, "qa")))
      .to eq(File.join(root, "qa", "bluebook", "quality_control.world"))
  end

  # Yields a scratch domain written with the given worlds (and hecksagon), removed afterwards.
  def with_domain(**options)
    Dir.mktmpdir { |dir| yield write_domain(dir, **options) }
  end

  it "picks the world named after the chapter the hecksagon attaches among several" do
    with_domain(worlds: %w[governance quality_control], hecksagon: %(Hecks::Chapters.load!("QualityControl")\n)) do |domain|
      expect(recipe.world_file_for(domain)).to eq(File.join(domain, "bluebook", "quality_control.world"))
    end
  end

  it "takes the sole world when it is not named after the directory" do
    with_domain(worlds: %w[only_one]) do |domain|
      expect(recipe.world_file_for(domain)).to eq(File.join(domain, "bluebook", "only_one.world"))
    end
  end

  it "refuses to guess among several worlds when none is attached by name", :aggregate_failures do
    with_domain(worlds: %w[governance quality_control]) do |domain|
      expect { recipe.world_file_for(domain) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/does not exist/).to_stderr
    end
  end
end
