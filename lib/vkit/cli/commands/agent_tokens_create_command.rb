# frozen_string_literal: true

require "json"
require "time"

module Vkit
  module CLI
    module Commands
      class AgentTokensCreateCommand < BaseCommand
        def call(options)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            response =
              authenticated_client.post(
                "/api/v1/orgs/#{org}/agent_tokens",
                body: build_body(options)
              )

            token  = response.fetch("token")
            secret = response.fetch("secret")

            puts "🔐 AGENT TOKEN ISSUED (shown once)"
            puts

            puts "🧠 Name:       #{token["name"]}"
            puts "📝 Label:      #{token["label"]}" if token["label"]
            puts "👤 Acts for:   #{acts_for(token)}"
            puts "🎭 Role:       #{token["role"]}"
            puts "🏢 Tenant:     #{token["tenant"]}" if token["tenant"]
            puts "🛡  Clearance:  #{token["clearance"]}" if token["clearance"]
            puts "🌍 Region:     #{token["region"]}" if token["region"]
            puts "🆔 Token ID:   #{token["id"]}"
            puts "🏷  Prefix:     #{token["prefix"]}"
            puts "⏳ Expires At: #{token["expires_at"] || "never"}"
            puts

            puts "🔑 TOKEN"
            puts "────────────────────────────────────────"
            puts secret
            puts "────────────────────────────────────────"
            puts

            puts "⚠️  Store this token securely. It cannot be retrieved again."

            warn_if_tenant_scoped(org) unless token["tenant"]
          end
        end

        private

        WARNING_NAMES = 5

        # A token with no tenant can't read a tenant-scoped dataset at all:
        # VaultKit answers it as if the dataset didn't exist. Say so when the
        # org has any, so the operator isn't left guessing why.
        def warn_if_tenant_scoped(org)
          names = tenant_scoped_datasets(org)
          return if names.empty?

          shown = names.first(WARNING_NAMES).join(", ")
          shown += ", and #{names.size - WARNING_NAMES} more" if names.size > WARNING_NAMES
          count = names.size == 1 ? "1 dataset is" : "#{names.size} datasets are"

          puts
          puts "⚠️  This token has no tenant, and #{count} tenant-scoped in #{org}: #{shown}."
          puts "   VaultKit answers its requests for them as if they didn't exist (\"Dataset not found\")."
          puts "   To read them, create a token for one tenant with --tenant."
        end

        # Names of datasets with a tenant column, from the registry export.
        # Nothing if the export can't be read: the token is already issued.
        def tenant_scoped_datasets(org)
          registry = authenticated_client.get("/api/v1/orgs/#{org}/registries/export")
          return [] unless registry.is_a?(Hash)

          registry.select { |_name, ds| ds.is_a?(Hash) && !ds["tenant_column"].to_s.empty? }.keys.sort
        rescue StandardError
          []
        end

        def build_body(options)
          body = {
            name: options.fetch(:name),
            label: options[:label],
            # Resolved to a member of your organization by the control plane.
            user_email: options[:for],
            role: options[:role],
            tenant: options[:tenant],
            clearance: options[:clearance],
            region: options[:region]
          }.compact

          if options[:expires_in]
            body[:expires_at] = parse_expires_in(options[:expires_in]).iso8601
          end

          body
        end

        def acts_for(token)
          person = token["acts_for"]
          return "no one (its requests show only to admins)" unless person

          person["name"] == person["email"] ? person["email"] : "#{person["name"]} <#{person["email"]}>"
        end

        def parse_expires_in(value)
          number = value.to_i
        
          case value
          when /\A\d+h\z/
            Time.now.utc + (number * 60 * 60)
          when /\A\d+d\z/
            Time.now.utc + (number * 24 * 60 * 60)
          else
            raise "Invalid expires_in format (use 1h, 24h, 30d)"
          end
        end        
      end
    end
  end
end
