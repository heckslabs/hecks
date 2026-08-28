require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# bin/project_deploy's own STACK_OUTPUTS/BASTION_PARAMETERS tables (its
# header explains why they're plain Ruby data, not a bluebook aggregate:
# this is the generator's own internal consistency, never touched by a
# human's input, checked once at generation time — not the kind of
# externally-supplied fact given/invariant exists for). This spec
# doesn't test those tables directly — bin/project_deploy is a script,
# not a library, and there's nothing to require — it tests the thing
# that actually matters: that the THREE GENERATED FILES still agree
# with each other, parsed back out of real output, not re-derived from
# the same table that could just as easily be wrong in the same way in
# all three places at once.
RSpec.describe "bin/project_deploy's stack<->bastion structural contract, in its own generated output",
               io: true do
  CONTRACT_FIXTURE_BASENAME = "project_deploy_contract_spec_fixture"

  # Mirrors spec/deploy_bluebook_spec.rb's own fixture helper —
  # bin/project_deploy always writes to <repo_root>/deploy/<basename>
  # regardless of where the source domain lives, so the basename here
  # is deliberately unique and the generated directory is removed
  # after every run.
  #
  # Generated ONCE, in `before(:context)`, and shared across every `it`
  # below — the three examples read three different facts out of the
  # identical fixture output, so re-running the real `bin/project_deploy`
  # subprocess (a fresh Ruby process booting the whole framework) once
  # per example was pure duplication, not three different checks.
  before(:context) do
    root = File.expand_path("..", __dir__)
    @generated_dir = File.join(root, "deploy", CONTRACT_FIXTURE_BASENAME)

    Dir.mktmpdir do |dir|
      domain_dir = File.join(dir, CONTRACT_FIXTURE_BASENAME)
      bluebook_dir = File.join(domain_dir, "bluebook")
      FileUtils.mkdir_p(bluebook_dir)

      File.write(File.join(bluebook_dir, "#{CONTRACT_FIXTURE_BASENAME}.bluebook"), <<~BLUEBOOK)
        Hecks.bluebook "Scratch" do
          aggregate "Thing" do
            identified_by :name
            attribute :name, ThingName
            value_object "ThingName" do
              attribute :value, String
              invariant("named") { !value.to_s.empty? }
            end
            command "Create" do
              attribute :name, ThingName
              sets :name
              emits "ThingCreated"
            end
          end
        end
      BLUEBOOK

      File.write(File.join(bluebook_dir, "#{CONTRACT_FIXTURE_BASENAME}.world"), <<~WORLD)
        Hecks.world "Scratch" do
          deployed_to("AwsLambda") do
            region "us-east-1"
          end
        end
      WORLD

      _stdout, stderr, status = Open3.capture3("ruby", File.join(root, "bin/project_deploy"), domain_dir)
      status.success? or raise "bin/project_deploy failed: #{stderr}"
    end

    @files = {
      template: File.read(File.join(@generated_dir, "template.yaml")),
      bastion:  File.read(File.join(@generated_dir, "bastion.yaml")),
      makefile: File.read(File.join(@generated_dir, "Makefile"))
    }
  end

  after(:context) { FileUtils.rm_rf(@generated_dir) }

  # bin/project_deploy assembles template.yaml/bastion.yaml through
  # heredocs and `#{}` interpolation -- nothing else in this file (or in
  # bin/project_deploy itself) ever parses the result back as YAML, so a
  # string-interpolation mistake that breaks YAML syntax is otherwise
  # only caught by an actual `sam deploy` failing against real AWS. Two
  # such bugs were already caught exactly that way: a non-ASCII em-dash
  # inside a GroupDescription string, and a generated password
  # containing "@" producing "found character '@' that cannot start any
  # token" (now excluded via ExcludeCharacters). CloudFormation's own
  # short-form intrinsic tags (!Sub, !Ref, !GetAtt, ...) parse fine as
  # plain untyped scalars under YAML.safe_load -- this doesn't need to
  # understand CloudFormation, only to confirm the interpolation
  # produced a well-formed YAML document at all.
  it "produces syntactically valid YAML for every generated CloudFormation template" do
    expect { YAML.safe_load(@files[:template], aliases: true) }.not_to raise_error
    expect { YAML.safe_load(@files[:bastion], aliases: true) }.not_to raise_error
  end

  it "gives every Makefile OutputKey lookup against the main stack a real template.yaml Output" do
    declared = @files[:template][/^Outputs:\n(.*)\z/m, 1].to_s.scan(/^  (\w+):$/).flatten
    queried = @files[:makefile].scan(/--stack-name \$\(STACK\) --query "Stacks\[0\]\.Outputs\[\?OutputKey=='(\w+)'\]/).flatten

    expect(queried).not_to be_empty
    expect(queried - declared).to eq([]),
                                  "Makefile queries #{queried - declared} against $(STACK), but template.yaml's Outputs only declares #{declared}"
  end

  it "gives every Makefile OutputKey lookup against the bastion stack a real bastion.yaml Output" do
    declared = @files[:bastion][/^Outputs:\n(.*)\z/m, 1].to_s.scan(/^  (\w+):$/).flatten
    queried = @files[:makefile].scan(/--stack-name \$\(BASTION_STACK\) --query "Stacks\[0\]\.Outputs\[\?OutputKey=='(\w+)'\]/).flatten

    expect(queried).not_to be_empty
    expect(queried - declared).to eq([]),
                                  "Makefile queries #{queried - declared} against $(BASTION_STACK), but bastion.yaml's Outputs only declares #{declared}"
  end

  it "fills every bastion.yaml Parameter from the Makefile's --parameter-overrides, and no others" do
    declared = @files[:bastion][/^Parameters:\n(.*?)^Resources:/m, 1].to_s.scan(/^  (\w+):$/).flatten
    overrides_line = @files[:makefile][/--parameter-overrides (.*?) \\/, 1].to_s
    filled = overrides_line.scan(/(\w+)=/).flatten

    expect(declared).not_to be_empty
    expect(filled.sort).to eq(declared.sort),
                           "bastion.yaml declares Parameters #{declared}, but --parameter-overrides fills #{filled}"
  end
end
