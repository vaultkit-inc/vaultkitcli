# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../policy/pack_integrity"
require_relative "../../policy/bundle_compiler"
require_relative "../../policy/approval_groups"

module Vkit
  module CLI
    module Commands
      class PolicyDeployCommand < BaseCommand
        def call(bundle_path:, org:, activate:, format: "human")
          with_auth do
            bundle_path = File.expand_path(bundle_path)
            raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)

            derived_org = credential_store.user["organization_slug"]

            raise "Unable to determine organization from credentials. Please login." \
              if derived_org.nil? || derived_org.empty?

            if org && org != derived_org
              raise <<~MSG
                Organization mismatch detected.

                  Authenticated organization: #{derived_org}
                  Provided via --org:          #{org}

                Refusing to deploy policy bundle to a different organization.
              MSG
            end

            org_slug = org || derived_org

            bundle = JSON.parse(File.read(bundle_path))
            Vkit::Policy::PackIntegrity.check_bundle!(bundle)

            response =
              begin
                upload(org_slug, bundle, activate)
              rescue Vkit::CLI::API::APIError => e
                raise conflict(e) if NEW_CONFLICT_CODES.include?(e.code)
                raise unless json?

                already_deployed(org_slug, bundle, e)
              end
            response = reuploaded(org_slug, response) if response["already_existed"]
            return respond(response) if response["already_deployed"] || response["already_existed"]

            warnings = deploy_warnings(org_slug, bundle, response)

            if format == "json"
              respond({ "org" => org_slug, "bundle_version" => response["bundle_version"],
                        "state" => response["state"], "checksum" => response["checksum"],
                        "warnings" => warnings, "already_deployed" => false })
            else
              print_deployed(org_slug, response, warnings)
            end
          end
        rescue Vkit::Policy::ValidationError => e
          raise if json?

          puts e.message
          exit 1
        end

        private

        # The 409s a control plane from vaultkit#126 on answers with a code.
        # Uploading the same bundle again isn't one of them: that's a 200
        # with already_existed (see #reuploaded).
        NEW_CONFLICT_CODES = %w[bundle_version_exists bundle_checksum_exists].freeze

        # The same bundle (version and checksum) uploaded before: nothing
        # was uploaded. With --activate the control plane also activates it
        # if it wasn't active, and doesn't say which, so "already deployed"
        # means it is the active bundle now without a new upload.
        def reuploaded(org_slug, response)
          version = response["bundle_version"]
          active = response["state"] == "active"
          if active
            puts "✓ Bundle #{version} was already uploaded and is the active one; nothing new to deploy."
          else
            puts "✓ Bundle #{version} was already uploaded (state: #{response['state']}); nothing new to upload."
          end
          { "org" => org_slug, "bundle_version" => version, "state" => response["state"],
            "checksum" => response["checksum"], "warnings" => [], "already_deployed" => active,
            "already_existed" => true }
        end

        # The conflicting version and its state come with the 409.
        def conflict(error)
          Vkit::CLI::CommandError.new(
            error.error.to_s, code: error.code, fix: [Vkit::CLI::ErrorMap::CONFLICT_FIXES.fetch(error.code)],
            result: { "conflicting_version" => error.body["bundle_version"], "state" => error.body["state"] }.compact
          )
        end

        # Each bundle version can be uploaded once. The control plane says
        # so with a 409 (a 500 in production, where its catch-all answers
        # first) and has no endpoint for the active bundle's checksum, only
        # its version (GET /setup, admins). So: the same version active, from
        # a clean commit, is already deployed; anything else is an error.
        def already_deployed(org_slug, bundle, error)
          raise error unless [409, 500].include?(error.status)

          version = bundle.dig("bundle", "bundle_version")
          active = active_version(org_slug)

          if active == version && bundle.dig("bundle", "source", "dirty") != true
            puts "✓ Bundle #{version} is already the active one; nothing to deploy."
            return { "org" => org_slug, "bundle_version" => version, "state" => "active",
                     "checksum" => bundle.dig("bundle", "checksum"), "warnings" => [], "already_deployed" => true }
          end

          raise error unless error.status == 409 || active

          raise Vkit::CLI::CommandError.new(
            "Bundle version #{version} was already uploaded#{" (the active one is #{active})" if active}, " \
            "and a version can only be deployed once.",
            code: "bundle_version_exists",
            fix: ["Commit your policy changes and rebuild with `vkit policy bundle` (the version is the commit), " \
                  "or name a new one with --version <label>."]
          )
        end

        def active_version(org_slug)
          setup = authenticated_client.get("/api/v1/orgs/#{org_slug}/setup")
          setup.is_a?(Hash) ? setup.dig("active_policy", "version") : nil
        rescue StandardError
          nil
        end

        def print_deployed(org_slug, response, warnings)
          puts "🚀 Policy bundle deployed"
          puts "   Org:     #{org_slug}"
          puts "   Version: #{response['bundle_version']}"
          puts "   State:   #{response['state']}"
          return if warnings.empty?

          puts
          warnings.each { |w| puts "⚠️  #{w['message']}" }
        end

        # The control plane returns one warning per approval group nobody is
        # in. Older control planes don't, so the same rule is applied here to
        # the groups they list. A failure to list them never fails the deploy.
        def deploy_warnings(org_slug, bundle, response)
          return Array(response["warnings"]) if response.is_a?(Hash) && response.key?("warnings")

          listed = authenticated_client.get("/api/v1/orgs/#{org_slug}/approval_groups")
          Vkit::Policy::ApprovalGroups.warnings(bundle, listed.is_a?(Hash) ? listed["groups"] : [])
        rescue StandardError
          []
        end

        # A control plane from before vaultkitcli#47 doesn't know installed_packs'
        # policy_ids and rejects the bundle on schema. The ids were checked
        # above, so send the bundle without them (re-checksummed) instead.
        def upload(org_slug, bundle, activate)
          post_bundle(org_slug, bundle, activate)
        rescue Vkit::CLI::API::APIError => e
          raise unless e.status == 422 && e.error.to_s.match?(%r{installed_packs/\d+/policy_ids})

          warn "ℹ️  This control plane predates per-pack policy checks; deploying without them."
          post_bundle(org_slug, without_policy_ids(bundle), activate)
        end

        def post_bundle(org_slug, bundle, activate)
          authenticated_client.post(
            "/api/v1/orgs/#{org_slug}/policy_bundles",
            body: {
              bundle: bundle,
              activate: activate
            }
          )
        end

        def without_policy_ids(bundle)
          copy = JSON.parse(JSON.generate(bundle))
          Array(copy.dig("bundle", "installed_packs")).each { |p| p.delete("policy_ids") }
          copy["bundle"]["checksum"] = ""
          copy["bundle"]["checksum"] = Digest::SHA256.hexdigest(Vkit::Policy::BundleCompiler.canonical_json(copy))
          copy
        end
      end
    end
  end
end
