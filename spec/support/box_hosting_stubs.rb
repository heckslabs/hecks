require "fileutils"
require "json"
require "open3"
require "tmpdir"

# Stand-ins for the `aws`, `docker` and `gh` programs, so the generated hosting scripts run end
# to end without touching AWS or GitHub. Every call is appended to `calls.log`; the stand-in AWS
# keeps a CloudFormation parameter file, so an `update-stack` changes what the next
# `describe-stacks` and `describe-task-definition` report, the way the real stack's
# TaskDefinition resource would.
module BoxHostingStubs
  ACCOUNT = "123456789012".freeze
  REGISTRY = "#{ACCOUNT}.dkr.ecr.us-east-1.amazonaws.com".freeze

  AWS = <<~'BASH'.freeze
    #!/usr/bin/env bash
    echo "aws $*" >> "$STUB_DIR/calls.log"
    args="$*"
    case "$1 $2" in
      "sts get-caller-identity") echo 123456789012 ;;
      "ecr get-login-password") echo secret ;;
      "ecr describe-images") [ -n "${STUB_ECR_HAS_TAG:-}" ] || exit 254 ;;
      "cloudformation describe-stacks")
        case "$args" in
          *InstanceId*) echo i-0abc ;;
          *DbEndpoint*) echo db.widget.example ;;
          *DbSecretArn*) echo arn:aws:secretsmanager:us-east-1:123456789012:secret:db ;;
          *StackStatus*) cat "$STUB_DIR/stack_status" ;;
          *ParameterKey,v:*) cat "$STUB_DIR/params.json" ;;
        esac ;;
      "cloudformation update-stack")
        [ -z "${STUB_NO_UPDATES:-}" ] || { echo "An error occurred (ValidationError): No updates are to be performed." >&2; exit 254; }
        for a in "$@"; do
          case "$a" in
            ParameterKey=*,ParameterValue=*) k="${a#ParameterKey=}"; k="${k%%,*}"; v="${a#*ParameterValue=}"
              jq --arg k "$k" --arg v "$v" 'map(if .k == $k then .v = $v else . end)' "$STUB_DIR/params.json" > "$STUB_DIR/p.tmp" \
                && mv "$STUB_DIR/p.tmp" "$STUB_DIR/params.json" ;;
          esac
        done
        echo arn:stack ;;
      "ecs describe-task-definition")
        case "$args" in
          *"[family,revision]"*) printf 'widget-platform\t7\n' ;;
          *"containerDefinitions[?name=="*)
            name="${args#*name==\'}"; name="${name%%\'*}"
            case "$name" in
              domain) param=EngineImageTag ;;
              *) param="$(tr '[:lower:]' '[:upper:]' <<< "${name:0:1}")${name:1}ImageTag" ;;
            esac
            td="${args#*--task-definition }"; td="${td%% *}"
            pin="$STUB_DIR/pin_${td//:/_}"
            if [ -f "$pin" ]; then tag="$(jq -r --arg n "$name" '.[$n]' "$pin")"
            else tag="$(jq -r --arg k "$param" '.[] | select(.k == $k) | .v' "$STUB_DIR/params.json")"; fi
            echo "123456789012.dkr.ecr.us-east-1.amazonaws.com/widget-${name}:${tag}" ;;
        esac ;;
      "ssm send-command") printf '%s' "$args" > "$STUB_DIR/last_command"; echo cmd-1 ;;
      "ssm get-command-invocation")
        case "$args" in
          *StandardOutputContent*)
            # The settle check asks for the Compose file and the container list; the roll only the file.
            if grep -q '===PS===' "$STUB_DIR/last_command"; then cat "$STUB_DIR/box_report"
            else sed '/^===PS===$/,$d' "$STUB_DIR/box_report"; fi ;;
          *) echo Success ;;
        esac ;;
    esac
  BASH

  DOCKER = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "docker $*" >> "$STUB_DIR/calls.log"
    # Read the password a login is given, as docker does, so the writer is not killed by SIGPIPE.
    case "$*" in *--password-stdin*) cat > /dev/null ;; esac
  BASH

  GH = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "gh $*" >> "$STUB_DIR/calls.log"
    case "$1 $2" in
      "auth status") ;;
      "repo view") echo acme/derived ;;
      "workflow run") touch "$STUB_DIR/dispatched" ;;
      "run list") echo 1; [ ! -e "$STUB_DIR/dispatched" ] || echo 2 ;;
      "run view") case "$*" in *status*) echo completed ;; *conclusion*) echo "${STUB_CONCLUSION:-success}" ;; esac ;;
    esac
  BASH

  DEPLOY_BOX = <<~BASH.freeze
    #!/usr/bin/env bash
    echo "deploy-box $*" >> "$STUB_DIR/calls.log"
  BASH

  module_function

  # @param golden_dir [String] a directory holding generated hosting scripts
  # @param real_box [Boolean] install the generated `deploy-box.sh` and the files it renders from,
  #   instead of a stand-in that only records its arguments
  # @yield [Runner] a scratch directory with the scripts and stand-in programs installed
  def with_runner(golden_dir, real_box: false)
    Dir.mktmpdir do |dir|
      scripts = File.join(dir, "scripts")
      FileUtils.mkdir_p([scripts, File.join(dir, "bin")])
      %w[deploy-service.sh smoke-after-deploy.sh].each { |f| FileUtils.cp(File.join(golden_dir, f), scripts) }
      if real_box
        FileUtils.cp(Dir.children(golden_dir).map { |f| File.join(golden_dir, f) }, scripts)
      else
        File.write(File.join(scripts, "deploy-box.sh"), DEPLOY_BOX)
      end
      { "aws" => AWS, "docker" => DOCKER, "gh" => GH }.each do |name, body|
        File.write(File.join(dir, "bin", name), body)
        File.chmod(0o755, File.join(dir, "bin", name))
      end
      yield Runner.new(dir)
    end
  end

  # Runs the copied scripts against the stand-in programs.
  class Runner
    attr_reader :dir

    def initialize(dir)
      @dir = dir
      stack_status("UPDATE_COMPLETE")
      parameters("WebsiteImageTag" => "website-old", "CmsImageTag" => "cms-old", "EngineImageTag" => "domain-old", "Other" => "x")
      box_report(compose: {}, containers: "")
    end

    # @param status [String] what every describe-stacks status query answers
    def stack_status(status) = File.write(File.join(dir, "stack_status"), "#{status}\n")

    # @param pairs [Hash{String => String}] the stack's parameters
    def parameters(pairs) = File.write(File.join(dir, "params.json"), JSON.generate(pairs.map { |k, v| { k: k, v: v } }))

    # @param compose [Hash{String => String}] service => image the box's compose.json holds
    # @param containers [String] `docker compose ps` lines, "<service> <status>"
    def box_report(compose:, containers:)
      json = JSON.generate(services: compose.transform_values { |image| { image: image } })
      File.write(File.join(dir, "box_report"), "#{json}\n===PS===\n#{containers}\n")
    end

    # Makes a family:revision name these image tags, whatever the stack's parameters say now.
    #
    # @param name [String] the task definition, such as "widget-platform:5"
    # @param tags [Hash{String => String}] container => image tag
    def pin_task_definition(name, tags) = File.write(File.join(dir, "pin_#{name.tr(":", "_")}"), JSON.generate(tags))

    # @return [Array<String>] the calls the stand-ins recorded, oldest first
    def calls
      path = File.join(dir, "calls.log")
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    # @return [Hash{String => String}] the stack's parameters now
    def current_parameters = JSON.parse(File.read(File.join(dir, "params.json"))).to_h { |row| [row["k"], row["v"]] }

    # @param script [String] the script's name
    # @return [Array(String, String, Process::Status)] stdout, stderr and status
    def run(script, *, env: {})
      Open3.capture3({ "PATH" => "#{File.join(dir, "bin")}:#{ENV.fetch("PATH")}", "STUB_DIR" => dir,
                       "SETTLE_CHECK_INTERVAL_SECS" => "1", "SETTLE_TIMEOUT_SECS" => "6",
                       "SSM_POLL_SECS" => "0.1" }.merge(env),
                     "bash", File.join(dir, "scripts", script), *)
    end
  end
end
