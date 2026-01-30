require "json"
require "fileutils"
require "open3"
require "rbconfig"

module Vkit
  module Core
    class CredentialStore
      SERVICE = "vkit"
      ACCOUNT = "credentials"

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

      def endpoint
        load_payload&.dig("endpoint")
      end

      def token
        load_payload&.dig("token")
      end

      def user
        load_payload&.dig("user")
      end

      def logged_in?
        !!(endpoint && token)
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
        payload = load_payload
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

      def load_payload
        case
        when mac?
          mac_keychain_load
        when linux? && secret_tool_available?
          linux_secret_service_load
        else
          file_load
        end
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
