require "net/http"
require "uri"
require "json"
require "openssl"

module Vkit
  module Core
    class AuthClient
      DEFAULT_BASE_URL = ENV["VKIT_ENDPOINT"] || "http://localhost:3000"

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

      private

      def uri_for(path)
        URI("#{@base_url}#{path}")
      end

      def http_get(uri)
        req = Net::HTTP::Get.new(uri)
        http_request(uri, req)
      end

      def http_request(uri, req, allow_non_200: false)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE

        res = http.request(req)

        return res if allow_non_200

        unless res.is_a?(Net::HTTPSuccess)
          raise "HTTP #{res.code}: #{res.body}"
        end

        res
      end

      def parse_json(res)
        JSON.parse(res.body)
      rescue JSON::ParserError
        raise "Invalid JSON response from server"
      end
    end
  end
end

