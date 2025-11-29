require "net/http"
require "uri"
require "json"

module Vkit
  module Core
    class FunlClient
      DEFAULT_BASE_URL = ENV["FUNL_URL"] || "https://kizzie-unfretting-lastly.ngrok-free.dev"

      def initialize(base_url: DEFAULT_BASE_URL)
        @base_url = base_url.chomp("/")
        @use_mock = ENV["VKIT_USE_MOCK_FUNL"] == "true"
      end

      # POST /execute
      # Body: { aql: <json>, options: { … } }
      # Headers: Authorization: Bearer <jwt>
      # Returns: rows (Array<Hash>) or []

      def execute(aql:, bearer:, datasource:, options: {})
        # return mock_execute(aql) if @use_mock

        aql_payload = JSON.parse(JSON.dump(aql))
        aql_payload["mask_fields"] = options[:mask_fields] if options[:mask_fields]

        body = {
          aql: aql_payload,
          datasource: datasource
        }

        uri = URI("#{@base_url}/execute")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Authorization"] = "Bearer #{bearer}" if bearer
        req.body = JSON.dump(body)

        res = http_request(uri, req)

        case res.code.to_i
        when 200
          JSON.parse(res.body)

        when 401
          raise "Funl unauthorized"

        else
          raise "Funl error (#{res.code}) #{res.body}"
        end
      end

      private

      def http_request(uri, req)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
          http.request(req)
        end
      end

      # ------------ Mocking Logic ------------ #

      def mock_execute(aql)
        dataset = aql["source_table"] || "unknown"
        fields  = extract_fields(aql)
        rows = generate_mock_data(fields, 5)

        puts "⚠️  Funl mock mode active (VKIT_USE_MOCK_FUNL=true)"
        puts "   dataset=#{dataset}, rows=#{rows.size}"

        rows
      end

      def extract_fields(aql)
        cols = (aql["columns"] || []).map { |f| f.to_s.split(".").last }
        aggs = (aql["aggregates"] || []).map { |h| h["alias"] || h["field"].to_s.split(".").last }
        (cols + aggs).uniq
      end

      def generate_mock_data(fields, count)
        count.times.map do
          fields.to_h { |f| [f, mock_value_for(f)] }
        end
      end

      def mock_value_for(field)
        case field
        when /email/     then "user#{rand(1000)}@example.com"
        when /name|user/ then ["ava","mia","zoe","liam","noah"].sample
        when /amount|total|spent|price/ then rand(20..2000)
        else ["alpha","beta","gamma","delta"].sample
        end
      end
    end
  end
end
