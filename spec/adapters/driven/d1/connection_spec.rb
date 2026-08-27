require "spec_helper"

# `Connection#response_results`'s own batched-statement failure path used to
# read `failed["error"] || failed["message"] || messages` — `||` cannot tell
# a genuinely stored `false` at "error" apart from a missing key, so a real
# `false` there silently fell through to "message" instead of being surfaced.
# No network call is exercised here — `Net::HTTP.start` is stubbed to hand
# back a scripted JSON body, so this proves the ruby-side fallback logic
# alone.
RSpec.describe Hecks::Adapters::D1::Connection do
  let(:connection) { described_class.new(account_id: "acc", database_id: "db", api_token: "tok") }

  def stub_http_response(json_body)
    fake_response = instance_double(Net::HTTPResponse, body: JSON.generate(json_body), code: "200")
    fake_http = instance_double(Net::HTTP, request: fake_response)
    allow(Net::HTTP).to receive(:start) { |*_args, &block| block.call(fake_http) }
  end

  it "surfaces a batched statement's own stored `false` error detail, not the `message` fallback" do
    stub_http_response(
      "success" => true,
      "result"  => [
        { "success" => false, "error" => false, "message" => "should never be used instead" }
      ]
    )

    expect { connection.execute("SELECT 1") }
      .to raise_error(Hecks::Runtime::WiringError, "D1 query failed: false")
  end

  it "still falls back to `message` when `error` is genuinely absent" do
    stub_http_response(
      "success" => true,
      "result"  => [
        { "success" => false, "message" => "a real failure detail" }
      ]
    )

    expect { connection.execute("SELECT 1") }
      .to raise_error(Hecks::Runtime::WiringError, "D1 query failed: a real failure detail")
  end
end
