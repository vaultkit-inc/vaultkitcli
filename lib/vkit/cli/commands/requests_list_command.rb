# frozen_string_literal: true

require "json"
require_relative "../../core/table_formatter"

module Vkit
  module CLI
    module Commands
      class RequestsListCommand < BaseCommand
        def call(state:, format:)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            params = {}
            params[:state] = state unless state == "all"

            response = authenticated_client.get(
              "/api/v1/orgs/#{org}/requests",
              params: params
            )

            render(response, format)
          end
        end

        private

        def render(rows, format)
          if rows.empty?
            puts "📭 No requests found"
            return
          end

          case format
          when "json"
            puts JSON.pretty_generate(rows)
          when "table"
            Vkit::Core::TableFormatter.render(rows)
          else
            raise "Unknown format: #{format}"
          end
        end
      end
    end
  end
end
