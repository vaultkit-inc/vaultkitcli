require "net/http"
require "uri"
require "json"
require "openssl"
require_relative "user_agent"

module Vkit
  module Core
    class AuthClient
      DEFAULT_BASE_URL = ENV["VKIT_ENDPOINT"] || "http://localhost:3000"

      # A non-2xx answer. The message is as it always was; status and body
      # let --format json say why (an expired login is a 401).
      class HTTPError < RuntimeError
        attr_reader :status, :body

        def initialize(status, body)
          @status = status.to_i
          @body = body
          super("HTTP #{status}: #{body}")
        end
      end

      def initialize(base_url: DEFAULT_BASE_URL)
        @base_url = base_url.chomp("/")
      end

      def discover
        uri = uri_for("/auth/cli")
        res = http_get(uri)
        parse_json(res)
      end

      def start_cli_login
        uri = uri_for("/auth/cli/start")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = "{}"

        res = http_request(uri, req)
        parse_json(res)
      end

      def poll_cli_login(poll_token)
        uri = uri_for("/auth/cli/poll")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.dump(
          poll_token: poll_token
        )
      
        http_request(uri, req, allow_non_200: true)
      end      

      def password_login(email:, password:)
        uri = uri_for("/api/users/sign_in")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.dump(
          user: {
            email: email,
            password: password
          }
        )

        res = http_request(uri, req)
        body = parse_json(res)

        {
          token: body["token"],
          user: body["user"]
        }
      end

      def whoami(token)
        uri = uri_for("/auth/whoami")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{token}"

        res = http_request(uri, req)
        body = parse_json(res)

        body["user"]
      end

      def logout(token)
        uri = uri_for("/api/users/sign_out")
        req = Net::HTTP::Delete.new(uri)
        req["Authorization"] = "Bearer #{token}"
      
        http_request(uri, req, allow_non_200: true)
      end      

      # Setup sessions (device authorization, RFC 8628 style): ask for one,
      # then poll until an admin approves or denies it in the console.
      def start_setup_session
        uri = uri_for("/api/setup_sessions")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/json"
        req.body = "{}"

        parse_json(http_request(uri, req))
      end

      # [HTTP status, body]: 200 with the token once approved; 400 with
      # error authorization_pending, slow_down, access_denied, expired_token
      # or invalid_grant; 429 rate_limited.
      def poll_setup_session(device_code)
        uri = uri_for("/api/setup_sessions/token")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Accept"] = "application/json"
        req.body = JSON.dump(device_code: device_code)

        res = http_request(uri, req, allow_non_200: true)
        body = begin
          JSON.parse(res.body.to_s)
        rescue JSON::ParserError
          { "error" => res.body.to_s }
        end
        [res.code.to_i, body]
      end

      # A setup token ending itself (DELETE /api/setup_sessions/current).
      # Raises HTTPError when the control plane doesn't confirm it.
      def end_setup_session(token)
        uri = uri_for("/api/setup_sessions/current")
        req = Net::HTTP::Delete.new(uri)
        req["Authorization"] = "Bearer #{token}"
        req["Accept"] = "application/json"

        parse_json(http_request(uri, req))
      end

      private

      def uri_for(path)
        URI("#{@base_url}#{path}")
      end

      def http_get(uri)
        req = Net::HTTP::Get.new(uri)
        http_request(uri, req)
      end

      def http_request(uri, req, allow_non_200: false)
        req["User-Agent"] = UserAgent.to_s
        res = build_http(uri).request(req)

        return res if allow_non_200

        unless res.is_a?(Net::HTTPSuccess)
          raise HTTPError.new(res.code, res.body)
        end

        res
      end

      # Certificates are verified against the system trust store. Point
      # SSL_CERT_FILE at a bundle to trust a self-signed control plane.
      def build_http(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http
      end

      def parse_json(res)
        JSON.parse(res.body)
      rescue JSON::ParserError
        raise "Invalid JSON response from server"
      end
    end
  end
end

