# THIS DOMAIN'S OWN LAMBDA ENTRY POINT — converts a Function URL event
# (API Gateway v2 payload format) into a Rack env, calls
# `Hecks::Adapters::Driving::GithubCiWebhook` (this domain's own driving
# adapter, qa/adapters/github_ci_webhook.rb), and converts the Rack
# response back. No new app code: a transport adapter only, the SAME
# shape hecksagain-embryonaut's own `lambda_handler.rb`
# (`WebLambdaHandler`) already established for a Sinatra app — this file
# wraps a plain Rack driving adapter instead, otherwise byte-for-byte
# the identical event/response translation.
#
# OPT-IN, BY FILE PRESENCE — `bin/project_deploy`'s own
# `web_handler_present` convention: this file's mere existence at
# qa/lambda_handler.rb is what makes `deployed_to("AwsLambda") {
# dispatch "None"; handler_module "QaWebhookLambdaHandler"; ... }`
# (qa/bluebook/quality_control.world) generate a WebFunction-shaped
# Lambda at all — see that generator's own header on why "dispatch
# None" reuses the WebFunction mechanism wholesale rather than inventing
# a second Ruby-Lambda shape.
#
# PUBLIC (AuthType: NONE, bin/project_deploy's own WebFunction) — GitHub
# itself has no way to sign into this stack's AWS account, so this
# Function URL is unauthenticated at the AWS layer, same as any public
# webhook receiver; `GithubWebhook#call`'s own HMAC signature check
# (verify_signature!, against GITHUB_WEBHOOK_SECRET below) is the REAL
# authentication boundary, checked on every request before anything
# else runs.
#
# CodeUri FOR THIS FUNCTION IS THIS WHOLE PROJECT'S OWN ROOT, NOT
# `qa/` ALONE (`bin/project_deploy`'s own `web_code_uri`/
# `pg_version_path` comments have the full reasoning) — `require` below
# resolves the SAME way Embryonaut's own web_handler_relpath does,
# relative to CodeUri (this project's root, at runtime `/var/task`).
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("Gemfile", "#{__dir__}/..")

require "rack"
require "stringio"
require "base64"

# FETCHED FROM SECRETS MANAGER HERE, at cold start, BEFORE requiring
# "hecks" below — the SAME exposure DATABASE_URL/SESSION_SECRET/
# GOOGLE_CLIENT_ID's own comments in WebLambdaHandler document:
# `lambda:GetFunctionConfiguration` returns any RESOLVED
# Environment.Variables value in plaintext to any read-only account
# principal, so this fetches the real GITHUB_WEBHOOK_SECRET value
# itself, at runtime, over the SDK, and never lets CloudFormation or
# Lambda's own configuration see it at all.
if ENV["DB_SECRET_ARN"]
  require "aws-sdk-secretsmanager"
  require "json"

  secrets_client = Aws::SecretsManager::Client.new

  db_secret = JSON.parse(secrets_client.get_secret_value(secret_id: ENV.fetch("DB_SECRET_ARN")).secret_string)
  ENV["DATABASE_URL"] = "postgres://postgres:#{db_secret.fetch('password')}@#{ENV.fetch('DB_HOST')}:5432/#{ENV.fetch('DB_NAME')}"

  if ENV["GITHUB_WEBHOOK_SECRET_ARN"]
    webhook_secret = JSON.parse(secrets_client.get_secret_value(secret_id: ENV.fetch("GITHUB_WEBHOOK_SECRET_ARN")).secret_string)
    ENV["GITHUB_WEBHOOK_SECRET"] = webhook_secret.fetch("value")
  end
end

require_relative "../lib/hecks"
require_relative "adapters/github_ci_webhook"

# WebLambdaHandler's own header explains the "not just LambdaHandler"
# naming gotcha (aws-lambda-ric's own internal class of that exact bare
# name) — restated here under this domain's own name for the same
# reason: `deployed_to("AwsLambda")`'s own `handler_module
# "QaWebhookLambdaHandler"` has to match this module's name exactly.
module QaWebhookLambdaHandler
  module_function

  def lambda_handler(event:, context:)
    env = build_rack_env(event)
    app = Hecks::Adapters::Driving::GithubCiWebhook.new(secret: ENV.fetch("GITHUB_WEBHOOK_SECRET"))
    status, headers, body = app.call(env)
    build_response(status, headers, body)
  end

  def build_rack_env(event)
    http = (event["requestContext"] || {})["http"] || {}
    raw_body = event["body"] || ""
    raw_body = Base64.decode64(raw_body) if event["isBase64Encoded"]
    headers = (event["headers"] || {}).transform_keys(&:downcase)

    env = base_rack_env(event, http, headers, raw_body)
    apply_headers!(env, headers)
    env["CONTENT_TYPE"]   = headers["content-type"] if headers["content-type"]
    env["CONTENT_LENGTH"] = raw_body.bytesize.to_s
    env
  end

  def base_rack_env(event, http, headers, raw_body)
    {
      "REQUEST_METHOD"    => http["method"] || "GET",
      "SCRIPT_NAME"       => "",
      "PATH_INFO"         => event["rawPath"].to_s,
      "QUERY_STRING"      => event["rawQueryString"].to_s,
      "SERVER_NAME"       => headers["host"] || "lambda",
      "SERVER_PORT"       => "443",
      "rack.version"      => Rack::VERSION,
      "rack.url_scheme"   => "https",
      "rack.input"        => StringIO.new(raw_body),
      "rack.errors"       => $stderr,
      "rack.multithread"  => false,
      "rack.multiprocess" => false,
      "rack.run_once"     => false
    }
  end

  # SKIPS content-length/content-type — Rack wants those set as
  # CONTENT_LENGTH/CONTENT_TYPE (no HTTP_ prefix), handled separately by
  # the caller, once each, not per-header here.
  def apply_headers!(env, headers)
    headers.each do |key, value|
      next if ["content-length", "content-type"].include?(key)

      env["HTTP_#{key.upcase.tr('-', '_')}"] = value
    end
  end

  def build_response(status, headers, body)
    full_body = +""
    body.each { |part| full_body << part }
    body.close if body.respond_to?(:close)

    {
      "statusCode"      => status,
      "headers"         => headers,
      "body"            => full_body,
      "isBase64Encoded" => false
    }
  end
end
