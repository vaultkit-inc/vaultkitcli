# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Vkit
  module CLI
    module API
      class Client
        DEFAULT_TIMEOUT = 15

        def initialize(base_url:, token:)
          raise ArgumentError, "base_url required" if base_url.nil?
          raise ArgumentError, "token required" if token.nil?

          @base_url = base_url.chomp("/")
          @token    = token
        end

        def get(path, params: {})
          request(method: :get, path: path, body: params.empty? ? nil : params)
        end

        def post(path, body:)
          request(method: :post, path: path, body: body)
        end

        def put(path, body:)
          request(method: :put, path: path, body: body)
        end

        def patch(path, body:)
          request(method: :patch, path: path, body: body)
        end

        private

        def request(method:, path:, body: nil)
          uri = URI("#{@base_url}#{path}")

          req = build_request(method, uri)
          req["Authorization"] = "Bearer #{@token}"
          req["Content-Type"]  = "application/json"
          req.body = JSON.dump(body) if body

          res = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: DEFAULT_TIMEOUT,
            read_timeout: DEFAULT_TIMEOUT
          ) do |http|
            http.request(req)
          end

          handle_response(res)
        end

        def build_request(method, uri)
          case method
          when :get   then Net::HTTP::Get.new(uri)
          when :post  then Net::HTTP::Post.new(uri)
          when :put   then Net::HTTP::Put.new(uri)
          when :patch then Net::HTTP::Patch.new(uri)
          else
            raise ArgumentError, "Unsupported HTTP method: #{method}"
          end
        end

        def handle_response(res)
          code = res.code.to_i
          body =
            if res.body.nil? || res.body.strip.empty?
              {}
            else
              JSON.parse(res.body) rescue { "error" => res.body }
            end
        
          case code
          when 200..299
            body
        
          when 403
            if body.is_a?(Hash) && body.key?("error")
              raise APIError.new(code, body["error"])
            else
              # Valid domain response (e.g. policy denied)
              body
            end
        
          when 202
            # Queued for approval
            body
        
          when 422
            raise APIError.new(code, body["error"] || body)
        
          else
            raise APIError.new(code, body["error"] || body)
          end
        end        
      end

      class APIError < StandardError
        attr_reader :status

        def initialize(status, message)
          @status = status
          super("API #{status}: #{message}")
        end
      end
    end
  end
end
