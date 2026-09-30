# Lambda entry point: turns a Function URL event into a Rack env for GithubCiWebhook
# and the Rack response back into a Lambda response.
#
# The Function URL is public; the webhook's HMAC signature check is the real auth boundary.
# CodeUri is the project root, so the requires below resolve from /var/task.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("Gemfile", "#{__dir__}/..")

require "rack"
require "stringio"
require "base64"

# Secrets are fetched here, before requiring "hecks", so they never pass through
# CloudFormation or the Lambda configuration (GetFunctionConfiguration exposes them).
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
require_relative "../lib/hecks/quality_control/adapters/github_ci_webhook"

# Must match the world file's handler_module; not named LambdaHandler because
# aws-lambda-ric defines a class of that name.
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

  # Rack expects CONTENT_TYPE and CONTENT_LENGTH without the HTTP_ prefix; the caller sets them.
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
