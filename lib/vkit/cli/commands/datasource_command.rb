# frozen_string_literal: true

require "json"
require_relative "../secret_input"

module Vkit
  module CLI
    module Commands
      class DatasourceCommand < BaseCommand
        REDACT = "[REDACTED]"

        # The password comes from the terminal (password_prompt) or an
        # environment variable (password_env). --password still works but is
        # deprecated: it ends up in shell history and agent transcripts.
        #
        # Adding an id that already exists with the same settings changes
        # nothing and isn't an error; with different settings it's a 409
        # datasource_exists (control planes from vaultkit#126 on compare
        # them; older ones are taken to mean the same). The control plane has
        # no way to change a stored credential, so a password source given
        # for an existing id isn't read.
        def add(id:, engine:, username:, config:, region:, environment:, password: nil,
                password_prompt: false, password_env: nil)
          warn_deprecated_password unless password.nil?
          Vkit::CLI::Output.register_secret(password)

          with_auth do
            user = require_admin!
            org  = user["organization_slug"]

            config_hash = parse_config(config)
            source = password_source(password, password_prompt, password_env)

            body = { name: id, engine: engine, username: username, region: region.upcase,
                     environment: environment, config: config_hash }

            existing = find(org, id)
            return already_exists(confirm_existing(org, body, existing), source) if existing

            password = read_password(source, id) unless source == :flag

            response = authenticated_client.post("/api/v1/orgs/#{org}/datasources", body: body.merge(password: password))
            return already_exists(response, source) if response["already_existed"]

            puts "✅ Datasource created:"
            print_datasource(response)
            respond(redacted(response).merge("already_existed" => false), scan_next_steps(id))
          end
        end

        def list
          with_auth do
            user = require_admin!
            org  = user["organization_slug"]

            rows = authenticated_client.get(
              "/api/v1/orgs/#{org}/datasources"
            )

            respond({ "datasources" => rows.map { |ds| redacted(ds) } })
            puts "📦 Datasources (#{rows.size}):"
            rows.each do |ds|
              print_datasource(ds)
              puts "-" * 40
            end
          end
        end

        def get(name)
          with_auth do
            user = require_admin!
            org  = user["organization_slug"]

            ds = authenticated_client.get(
              "/api/v1/orgs/#{org}/datasources/#{name}"
            )

            respond(redacted(ds))
            print_datasource(ds)
          end
        end

        private

        def require_admin!
          user = credential_store.user
          raise not_logged_in("Not logged in. Run: vkit login") unless user

          unless user["role"] == "admin"
            raise Vkit::CLI::CommandError.new(
              "⛔ Access denied: only admin users may manage datasources", code: "admin_required",
              fix: ["Ask an admin of the organization to add the datasource, or log in as one."]
            )
          end

          user
        end

        def parse_config(config)
          config ? JSON.parse(config) : {}
        rescue JSON::ParserError => e
          raise Vkit::CLI::CommandError.new("--config isn't valid JSON: #{e.message}", code: "invalid_config",
                                            fix: ["Pass --config as a JSON object, e.g. '{\"host\":\"db\",\"port\":5432,\"database\":\"app\"}'."])
        end

        # :flag, :prompt, :env, or nil when none was given.
        def password_source(password, prompt, env)
          given = [(:flag unless password.nil?), (:prompt if prompt), (:env if env)].compact
          if given.length > 1
            raise Vkit::CLI::CommandError.new("Give the password one way only.", code: "conflicting_password_sources",
                                              fix: ["Use either --password-prompt or --password-env VAR_NAME, not both."])
          end

          @password_env = env
          given.first
        end

        def read_password(source, id)
          case source
          when :prompt then Vkit::CLI::SecretInput.from_tty("Password for #{id}")
          when :env then Vkit::CLI::SecretInput.from_env(@password_env)
          else secret_required!
          end.tap { |value| Vkit::CLI::Output.register_secret(value) }
        end

        # No password source: an agent can't supply one, and shouldn't, so it
        # hands the command to the person.
        def secret_required!
          needs_input!(
            "secret_required", "The datasource's password is needed and wasn't given.",
            ["Ask the person to run this same command in their own terminal with --password-prompt " \
             "and type the password there (or set an environment variable and pass --password-env VAR_NAME)."]
          ) if json?

          raise Vkit::CLI::CommandError.new(
            "A password is required: use --password-prompt to type it, or --password-env VAR_NAME.",
            code: "secret_required", fix: []
          )
        end

        # nil when there's no datasource by that id.
        def find(org, id)
          authenticated_client.get("/api/v1/orgs/#{org}/datasources/#{id}")
        rescue Vkit::CLI::API::APIError => e
          raise unless e.status == 404

          nil
        end

        # The id exists: send the settings (no credential) and let the
        # control plane say whether they match. It answers 200
        # already_existed when they do and 409 datasource_exists when they
        # don't (raised as is). An older control plane answers neither (it
        # refuses the duplicate some other way), so the existing one stands.
        def confirm_existing(org, body, existing)
          response = authenticated_client.post("/api/v1/orgs/#{org}/datasources", body: body)
          response.is_a?(Hash) && response["already_existed"] ? response : existing
        rescue Vkit::CLI::API::APIError => e
          raise if e.code == "datasource_exists" || e.code.to_s.start_with?("setup_")

          existing
        end

        def already_exists(existing, source)
          puts "ℹ️  Datasource #{existing["name"]} already exists; left unchanged."
          result = redacted(existing).merge("already_existed" => true, "credential_updated" => false)
          if source
            note = "The control plane can't change a stored credential, so the password given wasn't used."
            puts "   #{note}"
            result["warning"] = note
          end
          respond(result, scan_next_steps(existing["name"]))
        end

        def scan_next_steps(id)
          ["vkit scan #{id} --mode apply --format json", "vkit registry export --force --format json"]
        end

        def warn_deprecated_password
          warn "⚠️  --password is deprecated: it ends up in shell history and agent transcripts. " \
               "Use --password-prompt (type it) or --password-env VAR_NAME."
        end

        def redacted(ds)
          {
            "name" => ds["name"] || ds[:name],
            "engine" => ds["engine"] || ds[:engine],
            "config" => ds["config"] || ds[:config],
            "region" => ds["region"] || ds[:region],
            "environment" => ds["environment"] || ds[:environment],
            "created_at" => ds["created_at"] || ds[:created_at],
            "updated_at" => ds["updated_at"] || ds[:updated_at]
          }.compact
        end

        def print_datasource(ds)
          puts JSON.pretty_generate(
            {
              name: ds["name"] || ds[:name],
              engine: ds["engine"] || ds[:engine],
              config: ds["config"] || ds[:config],
              username: REDACT,
              password: REDACT,
              created_at: ds["created_at"] || ds[:created_at],
              updated_at: ds["updated_at"] || ds[:updated_at]
            }
          )
        end
      end
    end
  end
end
