require "net/http"
require "uri"
require "json"

module Vkit
  module Core
    class AuthClient
      DEFAULT_BASE_URL = ENV["VKIT_AUTH_URL"] || "http://localhost:3000"

      def initialize(base_url: DEFAULT_BASE_URL)
        @base_url = base_url.chomp("/")
      end

      # POST /api/users/sign_in
      # Payload: { user: { email: ..., password: ... } }
      # Response: { token: "...", user: { email: ..., role: ..., organization_id: ... } }
      def login(email:, password:)
        uri = URI("#{@base_url}/api/users/sign_in")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.dump({ user: { email: email, password: password } })

        res = http_request(uri, req)
        case res.code.to_i
        when 200
          body = JSON.parse(res.body)
          { token: body["token"], user: body["user"] }
        when 401
          raise "Unauthorized: invalid credentials"
        when 422
          raise "Unprocessable Entity: check payload format"
        else
          raise "Login failed (#{res.code}) #{res.body}"
        end
      end

      private

      def http_request(uri, req)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE  # 🚨 temporary only

        http.request(req)
      end
    end
  end
end
