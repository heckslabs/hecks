require "openssl"
require "rack/utils"

module PizzaShop
  # The signature a payment processor puts on each webhook delivery, in the timestamped scheme
  # (`t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">`) that Stripe-style processors use.
  #
  # Kept apart from `PaymentWebhook` so the same scheme signs a delivery (`FakeProcessor`) and
  # checks one, and so the check can be read without the HTTP around it.
  module PaymentSignature
    # Raised for a delivery that cannot prove it came from the processor.
    class Invalid < StandardError; end

    # How far either side of now a delivery's timestamp may sit before it is refused as a
    # replay, in seconds.
    TOLERANCE = 300

    module_function

    # Signs a body the way the processor does.
    #
    # @param secret [String] the shared webhook signing secret
    # @param body [String] the exact bytes of the delivery
    # @param at [Time] the moment the delivery is signed
    # @return [String] the header value, `t=<unix seconds>,v1=<hex digest>`
    def sign(secret, body, at: Time.now)
      stamp = at.to_i
      "t=#{stamp},v1=#{digest(secret, stamp, body)}"
    end

    # Checks a delivery's signature header against its body.
    #
    # Compared in constant time: `==` leaks how many leading bytes of a forged digest matched.
    #
    # @param secret [String] the shared webhook signing secret
    # @param header [String, nil] the delivery's signature header value
    # @param body [String] the exact bytes of the delivery
    # @param now [Time] the moment the delivery arrived
    # @return [void]
    # @raise [Invalid] if the header is missing or malformed, the timestamp is outside
    #   `TOLERANCE`, or the digest does not match
    def verify!(secret, header, body, now: Time.now)
      stamp, signed = parts(header)
      raise Invalid, "the signature is #{(now.to_i - stamp).abs}s old, past #{TOLERANCE}s" if stale?(stamp, now)
      return if Rack::Utils.secure_compare(digest(secret, stamp, body), signed)

      raise Invalid, "the signature does not match the body"
    end

    # @api private
    def parts(header)
      fields = header.to_s.split(",").to_h { |pair| pair.split("=", 2) }
      raise Invalid, "no signature, or not in the t=…,v1=… form" unless fields["t"].to_s.match?(/\A\d+\z/) && fields["v1"]

      [fields["t"].to_i, fields["v1"]]
    end

    # @api private
    def stale?(stamp, now) = (now.to_i - stamp).abs > TOLERANCE

    # @api private
    def digest(secret, stamp, body)
      OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), secret, "#{stamp}.#{body}")
    end
  end
end
