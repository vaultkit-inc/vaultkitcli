require "json"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "auth_client"
require_relative "../cli/errors"

module Vkit
  module Core
    # Where vkit keeps its login: the OS keychain (or ~/.vkit), unless
    # VKIT_ENDPOINT and VKIT_TOKEN are both set, which then take over for
    # reading credentials without touching the saved login. That's for
    # scripts, CI and demos that shouldn't replace a person's own login.
    # `vkit login` and `vkit logout` always work on the saved login.
    class CredentialStore
      SERVICE = "vkit"
      ACCOUNT = "credentials"

      @override_noticed = false

      class << self
        attr_accessor :override_noticed
      end

      def initialize
        @os = RbConfig::CONFIG["host_os"]
        @fallback_path = File.join(Dir.home, ".vkit", "credentials.json")
      end

      def save(endpoint:, token:, user:)
        payload = {
          "endpoint" => endpoint,
          "token" => token,
          "user" => user
        }

        case
        when mac?
          mac_keychain_store(payload)
        when linux? && secret_tool_available?
          linux_secret_service_store(payload)
        else
          file_store(payload)
        end

        true
      end

      def save_user(user)
        if env_override
          @override_user = user
          return
        end

        payload = load_payload
        return unless payload
      
        payload["user"] = user
      
        case
        when mac?
          mac_keychain_store(payload)
        when linux? && secret_tool_available?
          linux_secret_service_store(payload)
        else
          file_store(payload)
        end
      end      

      def endpoint
        load_payload&.dig("endpoint")
      end

      def token
        load_payload&.dig("token")
      end

      def user
        override = env_override
        return override_user(override) if override

        stored_payload&.dig("user")
      end

      def logged_in?
        !!(endpoint && token)
      end

      # { "endpoint", "token" } from the environment, or nil when neither
      # variable is set. Exactly one of them set is a mistake worth stopping on.
      def env_override
        endpoint = ENV.fetch("VKIT_ENDPOINT", "").strip
        token = ENV.fetch("VKIT_TOKEN", "").strip
        return nil if endpoint.empty? && token.empty?

        if endpoint.empty? || token.empty?
          missing, given = endpoint.empty? ? %w[VKIT_ENDPOINT VKIT_TOKEN] : %w[VKIT_TOKEN VKIT_ENDPOINT]
          raise Vkit::CLI::Error,
                "#{given} is set but #{missing} isn't. Set both to use credentials from the environment, " \
                "or unset #{given} to use your saved login."
        end

        notice_override(endpoint)
        { "endpoint" => endpoint, "token" => token }
      end

      def clear!
        case
        when mac?
          mac_keychain_delete
        when linux? && secret_tool_available?
          linux_secret_service_delete
        else
          file_delete
        end
      end

      def clear_token!
        payload = stored_payload
        return unless payload
      
        payload.delete("token")
      
        case
        when mac?
          mac_keychain_store(payload)
        when linux? && secret_tool_available?
          linux_secret_service_store(payload)
        else
          file_store(payload)
        end
      end

      # endpoint and token only; the user is looked up separately (#user),
      # so reading the token never makes a network call.
      def load_payload
        env_override || stored_payload
      end

      def stored_payload
        case
        when mac?
          mac_keychain_load
        when linux? && secret_tool_available?
          linux_secret_service_load
        else
          file_load
        end
      end

      def override_user(override)
        @override_user ||= AuthClient.new(base_url: override["endpoint"]).whoami(override["token"])
      end

      def notice_override(endpoint)
        return if self.class.override_noticed

        self.class.override_noticed = true
        warn "vkit: using VKIT_ENDPOINT (#{endpoint}) and VKIT_TOKEN from the environment; your saved login is not used."
      end

      def mac?
        @os =~ /darwin/
      end

      def linux?
        @os =~ /linux/
      end

      def secret_tool_available?
        system("which secret-tool > /dev/null 2>&1")
      end

      def mac_keychain_store(payload)
        mac_keychain_delete
        system(
          "security", "add-generic-password",
          "-a", ACCOUNT,
          "-s", SERVICE,
          "-w", payload.to_json,
          "-U"
        )
      end

      def mac_keychain_load
        stdout, _stderr, status =
          Open3.capture3(
            "security", "find-generic-password",
            "-a", ACCOUNT,
            "-s", SERVICE,
            "-w"
          )

        return nil unless status.success?
        JSON.parse(stdout)
      rescue
        nil
      end

      def mac_keychain_delete
        system(
          "security", "delete-generic-password",
          "-a", ACCOUNT,
          "-s", SERVICE,
          out: File::NULL,
          err: File::NULL
        )
      end

      def linux_secret_service_store(payload)
        Open3.capture3(
          "secret-tool",
          "store",
          "--label=VaultKit Credentials",
          "service", SERVICE,
          "account", ACCOUNT,
          stdin_data: payload.to_json
        )
      end

      def linux_secret_service_load
        stdout, _stderr, status =
          Open3.capture3(
            "secret-tool",
            "lookup",
            "service", SERVICE,
            "account", ACCOUNT
          )

        return nil unless status.success?
        JSON.parse(stdout)
      rescue
        nil
      end

      def linux_secret_service_delete
        linux_secret_service_store({})
      end

      def file_store(payload)
        FileUtils.mkdir_p(File.dirname(@fallback_path))
        File.write(@fallback_path, JSON.pretty_generate(payload))
        File.chmod(0o600, @fallback_path)
      end

      def file_load
        return nil unless File.exist?(@fallback_path)
        JSON.parse(File.read(@fallback_path))
      rescue
        nil
      end

      def file_delete
        FileUtils.rm_f(@fallback_path)
      end
    end
  end
end
