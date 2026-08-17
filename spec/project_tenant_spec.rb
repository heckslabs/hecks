require "tmpdir"
require "fileutils"
require "open3"
require_relative "support/postgres_probe"

# bin/project_tenant is a SCRIPT, not a library — same reasoning
# project_deploy_contract_spec.rb's own header gives: there's nothing
# to require, so this runs it as a real subprocess (Open3) against a
# real tmpdir fixture and reads back what it actually produced, the
# same way bin/project_deploy's own contract spec does.
RSpec.describe "bin/project_tenant", io: true do
  ROOT = File.expand_path("..", __dir__).freeze
  SCRIPT = File.join(ROOT, "bin/project_tenant").freeze
  DB = "hecksagain_project_tenant_spec".freeze

  def fixture(dir)
    File.write(File.join(dir, "scratch.bluebook"), <<~BLUEBOOK)
      Hecks.bluebook "Scratch" do
        vision "one aggregate, enough to exercise bin/project_tenant end to end"
        core

        aggregate "Widget" do
          description "a widget"
          identified_by :ref

          value_object "Ref" do
            attribute :value, String
            invariant("a widget has a ref") { !value.to_s.empty? }
          end

          attribute :ref, Ref

          command "Make" do
            role "Someone"
            goal "make a widget"
            attribute :ref, Ref
            emits "WidgetMade"
          end

          query "All" do
          end
        end
      end
    BLUEBOOK
    File.write(File.join(dir, "scratch.hecksagon"), <<~HECKSAGON)
      Hecks.hecksagon "Scratch" do
        uses_framework "Governance"
        Scratch::Widget.persisted_by("PostgresEra")
      end
    HECKSAGON
    File.write(File.join(dir, "scratch.world"), <<~WORLD)
      Hecks.world "Scratch" do
        realm "ScratchDefault"
      end
    WORLD
  end

  def run_project_tenant(dir, slug, **opts)
    args = [SCRIPT, dir, slug]
    opts.each { |k, v| args << "--#{k}=#{v}" }
    Open3.capture3(*args)
  end

  before(:context) do
    skip_message = "no local Postgres reachable" unless PostgresProbe.available?
    @skip = skip_message
    next if skip_message

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DB} WITH (FORCE)")
    admin.exec("CREATE DATABASE #{DB}")
    admin.close
  end

  after(:context) do
    next if @skip

    admin = PG.connect(dbname: "postgres")
    admin.exec("DROP DATABASE IF EXISTS #{DB} WITH (FORCE)")
    admin.close
  end

  it "validates, provisions the schema, writes the overlay, and boots for real" do
    skip @skip if @skip

    Dir.mktmpdir do |dir|
      fixture(dir)

      out, err, status = run_project_tenant(
        dir, "acme", domain: "Scratch", realm: "Acme", schema: "acme", database: DB
      )
      expect(status).to be_success, "stdout: #{out}\nstderr: #{err}"
      expect(out).to include("wrote #{File.join(dir, 'environments/acme.world')}")
      expect(out).to include('booted Scratch for tenant "acme"')
      expect(out).to include("tenant_capable?")

      overlay = File.read(File.join(dir, "environments/acme.world"))
      expect(overlay).to include('realm "Acme"')
      expect(overlay).to include("database \"#{DB}\"")
      expect(overlay).to include('schema   "acme"')
    end
  end

  it "is idempotent — a second run for the same tenant is a safe no-op, not an error" do
    skip @skip if @skip

    Dir.mktmpdir do |dir|
      fixture(dir)

      run_project_tenant(dir, "acme", domain: "Scratch", realm: "Acme", schema: "acme", database: DB)
      _out, _err, status = run_project_tenant(dir, "acme", domain: "Scratch", realm: "Acme", schema: "acme", database: DB)

      expect(status).to be_success
    end
  end

  it "keeps two tenants it provisions completely apart, through the real overlays it wrote" do
    skip @skip if @skip

    Dir.mktmpdir do |dir|
      fixture(dir)

      run_project_tenant(dir, "acme", domain: "Scratch", realm: "Acme", schema: "acme", database: DB)
      run_project_tenant(dir, "bloom", domain: "Scratch", realm: "Bloom", schema: "bloom", database: DB)

      acme  = Hecks.boot(dir, environment: "acme", install_facade: false)
      bloom = Hecks.boot(dir, environment: "bloom", install_facade: false)

      register = Hecksagain::Bluebook::ProjectRegister.new
      register.register([acme.registry.bluebook("Scratch")], acme.registry, acme, dir)
      register.register([bloom.registry.bluebook("Scratch")], bloom.registry, bloom, dir)

      router = Hecksagain::Router.new(register)
      router.dispatch("Acme::Scratch::Widget.Make", ref: { value: "acme-provisioned-for-real" })

      expect(router.query("Acme::Scratch::Widget.all").map { |w| w[:ref][:value] }).to eq(["acme-provisioned-for-real"])
      expect(router.query("Bloom::Scratch::Widget.all")).to eq([])
    end
  end

  it "refuses a malformed tenant before writing or connecting to anything" do
    skip @skip if @skip

    Dir.mktmpdir do |dir|
      fixture(dir)

      _out, err, status = run_project_tenant(
        dir, "Not A Slug", domain: "Scratch", realm: "Bad", schema: "acme", database: DB
      )

      expect(status).not_to be_success
      expect(err).to include("is invalid")
      expect(File.exist?(File.join(dir, "environments/not a slug.world"))).to be false
    end
  end
end
