require "tmpdir"
require "fileutils"
require "open3"
require "yaml"

# Checks that the generated template.yaml, bastion.yaml and Makefile agree with each other,
# parsed back out of real bin/project_deploy output rather than re-derived from its tables.
RSpec.describe "bin/project_deploy's stack<->bastion structural contract, in its own generated output", :io do
  CONTRACT_FIXTURE_BASENAME = "project_deploy_contract_spec_fixture".freeze

  # bin/project_deploy always writes to <repo_root>/deploy/<basename>, so the basename is
  # unique. Generated once and shared by every example.
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

  # Interpolation mistakes that break YAML syntax would otherwise surface only in a real
  # `sam deploy`. Short-form tags (!Sub, !Ref) parse as plain scalars under safe_load.
  it "produces syntactically valid YAML for every generated CloudFormation template" do
    expect { YAML.safe_load(@files[:template], aliases: true) }.not_to raise_error
    expect { YAML.safe_load(@files[:bastion], aliases: true) }.not_to raise_error
  end

  it "gives every Makefile OutputKey lookup against the main stack a real template.yaml Output" do
    declared = @files[:template][/^Outputs:\n(.*)\z/m, 1].to_s.scan(/^  (\w+):$/).flatten
    queried = @files[:makefile].scan(/--stack-name \$\(STACK\) --query "Stacks\[0\]\.Outputs\[\?OutputKey=='(\w+)'\]/).flatten

    expect(queried).not_to be_empty
    expect(queried - declared).to eq([]),
                                  "Makefile queries #{queried - declared} against $(STACK), but template.yaml's " \
                                  "Outputs only declares #{declared}"
  end

  it "gives every Makefile OutputKey lookup against the bastion stack a real bastion.yaml Output" do
    declared = @files[:bastion][/^Outputs:\n(.*)\z/m, 1].to_s.scan(/^  (\w+):$/).flatten
    queried = @files[:makefile].scan(/
      --stack-name\ \$\(BASTION_STACK\)\ --query\ "Stacks\[0\]\.Outputs\[\?OutputKey=='(\w+)'\]
    /x).flatten

    expect(queried).not_to be_empty
    expect(queried - declared).to eq([]),
                                  "Makefile queries #{queried - declared} against $(BASTION_STACK), but " \
                                  "bastion.yaml's Outputs only declares #{declared}"
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
