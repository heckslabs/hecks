require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"

# `hecks deploy data_copy.restore` and `data_copy.verify` end to end: the Deploy chapter's DataCopy
# and CopyVerification ask the DeployToolchain port, the Hecks domain binds its adapter, and the
# generated `restore-to-rds.sh` and `verify-copy.sh` (the migration golden files) run against
# stand-in `aws`, `psql`, `pg_dump` and `pg_restore` programs. Nothing reaches AWS or a database.
RSpec.describe "the Deploy chapter's DataCopy and CopyVerification", :io do
  let(:golden) { File.join(__dir__, "fixtures", "deploy_box_golden", "migration") }

  AWS_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "aws $*" >> "$STUB_DIR/calls.log"
    [ -z "${STUB_AWS_FAIL:-}" ] || { echo "aws: unreachable" >&2; exit 255; }
    case "$1 $2" in
      "secretsmanager get-secret-value") echo '{"username":"copier","password":"hunter2"}' ;;
      "ssm start-session") echo "Waiting for connections..."; exec sleep 30 ;;
    esac
  BASH

  # Answers the queries the two scripts make, by what they ask. Port 15432 and 15434 are the source
  # side, 15433 and 15435 the target. The count and structure answers come from files a spec sets.
  PSQL_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    if [ "$1" = "--version" ]; then echo "psql (PostgreSQL) 16.2"; exit 0; fi
    port=""; query=""
    while [ $# -gt 0 ]; do
      case "$1" in -p) port="$2"; shift ;; -Atc|-qAtc) query="$2"; shift ;; esac
      shift
    done
    case "$port" in 15432|15434) side=source ;; *) side=target ;; esac
    echo "psql $side $query" >> "$STUB_DIR/calls.log"
    case "$query" in
      *"show server_version"*) echo 16.2 ;;
      *"from pg_namespace where nspname="*) [ "$side" = source ] && echo 1 || cat "$STUB_DIR/target_has_schema" ;;
      *matviewname*) ;;
      *query_to_xml*) cat "$STUB_DIR/counts_$side" ;;
      *"pg_class c join"*) cat "$STUB_DIR/shape_$side" ;;
      *"count(*) from pg_matviews"*) echo 0 ;;
    esac
  BASH

  PG_DUMP_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    if [ "$1" = "--version" ]; then echo "pg_dump (PostgreSQL) 16.2"; exit 0; fi
    echo "pg_dump $*" >> "$STUB_DIR/calls.log"
    echo dump
  BASH

  PG_RESTORE_STUB = <<~BASH.freeze
    #!/usr/bin/env bash
    if [ "$1" = "--version" ]; then echo "pg_restore (PostgreSQL) 16.2"; exit 0; fi
    echo "pg_restore $*" >> "$STUB_DIR/calls.log"
    cat > /dev/null
    echo "pg_restore: error: could not execute query: function hecks_tr_extract does not exist" >&2
    [ -z "${STUB_RESTORE_ERROR:-}" ] || echo "pg_restore: error: could not execute query: permission denied" >&2
  BASH

  # The scripts and stand-in programs in a scratch directory; `dir` is where the project lives.
  class Scratch
    attr_reader :dir

    def initialize(dir, golden)
      @dir = dir
      FileUtils.mkdir_p([File.join(dir, "bin"), File.join(dir, "project")])
      %w[restore-to-rds.sh verify-copy.sh].each { |f| FileUtils.cp(File.join(golden, f), File.join(dir, "project")) }
      { "aws" => AWS_STUB, "psql" => PSQL_STUB, "pg_dump" => PG_DUMP_STUB, "pg_restore" => PG_RESTORE_STUB }
        .each do |name, body|
        File.write(File.join(dir, "bin", name), body)
        File.chmod(0o755, File.join(dir, "bin", name))
      end
      target_has_schema(0)
      databases(counts: "widgets.orders|5\nwidgets_cms.posts|2\n", shape: "widgets r|3\npolicies|1\n")
    end

    def project = File.join(dir, "project")

    def target_has_schema(count) = File.write(File.join(dir, "target_has_schema"), "#{count}\n")

    # Makes each side report these table counts and this structure; `target_counts` overrides one.
    def databases(counts:, shape:, target_counts: counts)
      { "counts_source" => counts, "counts_target" => target_counts,
        "shape_source" => shape, "shape_target" => shape }.each { |name, text| File.write(File.join(dir, name), text) }
    end

    def calls
      path = File.join(dir, "calls.log")
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end
  end

  COPY_ARGS = %w[bastion=i-0abc123 source=old.db.example source_secret=arn:old target=new.db.example
                 target_secret=arn:new].freeze

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
  end

  def with_scratch(&)
    Dir.mktmpdir { |dir| yield Scratch.new(dir, golden) }
  end

  # Runs the verb with the stand-in programs first on PATH, as the generated scripts find them.
  def command(scratch, verb, *argv, env: {})
    settings = { "PATH" => "#{File.join(scratch.dir, 'bin')}:#{ENV.fetch('PATH')}", "STUB_DIR" => scratch.dir }
    saved = ENV.to_h.slice(*settings.merge(env).keys)
    ENV.update(settings.merge(env))
    out, status = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                               argv: ["deploy", verb, scratch.project, *argv, "--wait"])
    [JSON.parse(out), status]
  ensure
    settings.merge(env).each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  def verification_status(json)
    out, = Hecks::Doors::CliRunner.call(runtime: @hecks, program: "hecks",
                                        argv: ["deploy", "copy_verification.verdict", "run=#{json.fetch('run')}"])
    JSON.parse(out).first&.fetch("status")
  end

  def tunnels(scratch) = scratch.calls.grep(/\Aaws ssm start-session/).size

  it "declares both aggregates in the Deploy chapter, joined by policies" do
    chapter = @hecks.registry.bluebook("Deploy")

    expect(chapter.aggregate("DataCopy").commands.map(&:hecks_name))
      .to eq(%w[Restore Verify Complete Plan Flag Confirm Drift FlagVerification])
    expect(chapter.aggregate("CopyVerification").commands.map(&:hecks_name)).to eq(%w[Run Match Differ Flag])
  end

  describe "data_copy.restore" do
    it "refuses without confirm=true, names what it would overwrite, and touches nothing" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.restore", *COPY_ARGS)

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(json.dig("state", "refusal", "value")).to include(
          "refusing to restore", "schemas widgets, widgets_cms", "database widgetdb on new.db.example",
          "OVERWRITING", "confirm=true"
        )
        expect(scratch.calls).to be_empty
        expect(verification_status(json)).to be_nil
      end
    end

    it "prints the plan for dry_run=true, runs nothing and requests no verification" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "dry_run=true", "force=true")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("planned")
        expect(json.dig("state", "report", "value")).to include("schemas widgets, widgets_cms", "force=true drops",
                                                                "dry run: nothing was run")
        expect(scratch.calls).to be_empty
        expect(verification_status(json)).to be_nil
      end
    end

    it "copies each schema, then the policy verifies, and one run key covers both" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true")

        expect(status).to eq(0), json.to_json
        expect(json.dig("state", "status")).to eq("verified")
        expect(json.dig("state", "verification", "value")).to include("OK: 2 tables")
        expect(scratch.calls.grep(/\Apg_dump/).map { |c| c[/--schema=(\S+)/, 1] }).to eq(%w[widgets widgets_cms])
        expect(verification_status(json)).to eq("verified")
        expect(tunnels(scratch)).to eq(4), "the script verified a second time"
      end
    end

    it "marks the copy drifted, and exits 1, when the databases differ afterwards" do
      with_scratch do |scratch|
        scratch.databases(counts: "widgets.orders|5\n", target_counts: "widgets.orders|4\n", shape: "widgets r|3\n")

        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true")

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("drifted")
        expect(json.dig("state", "refusal", "value")).to include("row counts differ")
        expect(verification_status(json)).to eq("drifted")
      end
    end

    it "leaves the verification out for skip_verify=true" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true", "skip_verify=true")

        expect(status).to eq(0)
        expect(json.dig("state", "status")).to eq("restored")
        expect(tunnels(scratch)).to eq(2)
        expect(verification_status(json)).to be_nil
      end
    end

    it "flags a target that already has the schemas as exit 61, copying nothing" do
      with_scratch do |scratch|
        scratch.target_has_schema(1)

        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true")

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(json.dig("state", "refusal", "value")).to include("restore ended 61", "re-run with FORCE=1")
        expect(scratch.calls.grep(/\Apg_dump/)).to be_empty
      end
    end

    it "drops the target schemas first for force=true" do
      with_scratch do |scratch|
        scratch.target_has_schema(1)

        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true", "force=true")

        expect(status).to eq(0), json.to_json
        expect(scratch.calls.grep(/psql target drop schema "widgets"/)).not_to be_empty
        expect(scratch.calls.grep(/\Apg_dump/).size).to eq(2)
      end
    end

    it "flags restore errors other than the known one as exit 62, and runs no verification" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true",
                               env: { "STUB_RESTORE_ERROR" => "1" })

        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("restore ended 62", "permission denied")
        expect(verification_status(json)).to be_nil
      end
    end

    it "refuses a project with no restore script, naming script=<path>" do
      with_scratch do |scratch|
        FileUtils.rm(File.join(scratch.project, "restore-to-rds.sh"))

        json, status = command(scratch, "data_copy.restore", *COPY_ARGS, "confirm=true")

        expect(status).to eq(1)
        expect(json.dig("state", "refusal", "value")).to include("no restore-to-rds.sh", "script=<path>")
      end
    end

    it "refuses a bastion that is not an instance id" do
      with_scratch do |scratch|
        out, status = Hecks::Doors::CliRunner.call(
          runtime: @hecks, program: "hecks",
          argv: ["deploy", "data_copy.restore", scratch.project, *COPY_ARGS.drop(1), "bastion=not-one", "--wait"]
        )

        expect(status).not_to eq(0)
        expect(out).to include("Bastion")
      end
    end
  end

  describe "data_copy.verify" do
    it "compares the databases on its own and records a match" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.verify", *COPY_ARGS)

        expect(status).to eq(0), json.to_json
        expect(json.dig("state", "status")).to eq("verified")
        expect(json.dig("state", "verification", "value")).to include("OK: 2 tables")
        expect(verification_status(json)).to eq("verified")
        expect(scratch.calls.grep(/\Apg_dump/)).to be_empty
      end
    end

    it "records drifted, with the differing counts, and exits 1" do
      with_scratch do |scratch|
        scratch.databases(counts: "widgets.orders|5\n", target_counts: "widgets.orders|9\n", shape: "widgets r|3\n")

        json, status = command(scratch, "data_copy.verify", *COPY_ARGS)

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("drifted")
        expect(json.dig("state", "refusal", "value")).to include("FAIL: row counts differ", "widgets.orders")
        expect(verification_status(json)).to eq("drifted")
      end
    end

    it "records flagged, not drifted, when the comparison cannot be made" do
      with_scratch do |scratch|
        json, status = command(scratch, "data_copy.verify", *COPY_ARGS, env: { "STUB_AWS_FAIL" => "1" })

        expect(status).to eq(1)
        expect(json.dig("state", "status")).to eq("flagged")
        expect(json.dig("state", "refusal", "value")).to include("verify ended 255", "aws: unreachable")
      end
    end
  end
end
