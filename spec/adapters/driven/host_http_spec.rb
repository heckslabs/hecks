require "spec_helper"
require "socket"
require "json"
require "openssl"
require_relative "../../../lib/hecks/hecks/adapters/host_http"

# The HostHttp port's adapter runs the signed-webhook checks against a service, with the signing
# secret taken from the environment and never from a command argument.
RSpec.describe Hecks::Adapters::HostHttp do
  let(:adapter) { described_class.new }

  it "refuses without a signing secret in the environment" do
    stub_const("ENV", ENV.to_h.merge("SMOKE_WEBHOOK_SECRET" => nil))

    expect { adapter.probe(path: { value: "/hook" }) }
      .to raise_error(ArgumentError, /SMOKE_WEBHOOK_SECRET/)
  end

  it "refuses a scheme it cannot sign with" do
    stub_const("ENV", ENV.to_h.merge("SMOKE_WEBHOOK_SECRET" => "s"))

    expect { adapter.probe(path: { value: "/hook" }, scheme: { value: "md5" }) }
      .to raise_error(ArgumentError, /unknown scheme/)
  end

  it "reads the request body from a payload file", :io do
    stub_const("ENV", ENV.to_h.merge("SMOKE_WEBHOOK_SECRET" => "s"))
    server = TCPServer.new("127.0.0.1", 0)
    seen = []
    thread = Thread.new do
      loop do
        client = server.accept
        head = client.gets("\r\n\r\n")
        length = head[/Content-Length: (\d+)/i, 1].to_i
        seen << client.read(length) if length.positive?
        client.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    end
    file = File.join(Dir.tmpdir, "hecks-hook-payload-#{Process.pid}.json")
    File.write(file, %({"kind":"from-file"}))

    expect do
      adapter.probe(url: { value: "http://127.0.0.1:#{server.addr[1]}" }, path: { value: "/hook" },
                    payload_file: { value: file })
    end.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /FAILED/)
    expect(seen).to include(%({"kind":"from-file"}))
  ensure
    thread&.kill
    server&.close
    File.delete(file) if file && File.exist?(file)
  end
end
