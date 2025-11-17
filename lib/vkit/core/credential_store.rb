require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "base64"

module Vkit
  module Core
    class CredentialStore
      SERVICE = "vkit"
      ACCOUNT = "auth_token"

      def initialize
        @os = RbConfig::CONFIG["host_os"]
        @fallback_path = File.join(Dir.home, ".vkit", "credentials.json")
      end

      def save_token(token:, user:)
        case
        when mac?
          mac_keychain_store(token, user)
        when linux? && secret_tool_available?
          linux_secret_service_store(token, user)
        when windows?
          file_store(token, user) # simple fallback; can enhance with DPAPI
        else
          file_store(token, user)
        end
        true
      end

      def load_token
        data = case
               when mac?
                 mac_keychain_load
               when linux? && secret_tool_available?
                 linux_secret_service_load
               when windows?
                 file_load
               else
                 file_load
               end
        return nil unless data
        data["token"]
      end

      def load_user
        data = case
               when mac?
                 mac_keychain_load
               when linux? && secret_tool_available?
                 linux_secret_service_load
               when windows?
                 file_load
               else
                 file_load
               end
        return nil unless data
        data["user"]
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

      private

      def mac?
        @os =~ /darwin/
      end

      def linux?
        @os =~ /linux/
      end

      def windows?
        @os =~ /mswin|mingw|cygwin/
      end

      def secret_tool_available?
        system("which secret-tool > /dev/null 2>&1")
      end

      # ---------- macOS Keychain ----------
      def mac_keychain_store(token, user)
        payload = { token: token, user: user }.to_json
        # delete any existing entry first
        mac_keychain_delete
        cmd = [
          "security", "add-generic-password",
          "-a", ACCOUNT,
          "-s", SERVICE,
          "-w", payload,
          "-U" # update if exists
        ]
        system(*cmd)
      end

      def mac_keychain_load
        stdout, _stderr, status = Open3.capture3("security", "find-generic-password", "-a", ACCOUNT, "-s", SERVICE, "-w")
        return nil unless status.success?
        JSON.parse(stdout)
      rescue
        nil
      end

      def mac_keychain_delete
        system("security", "delete-generic-password", "-a", ACCOUNT, "-s", SERVICE, out: File::NULL, err: File::NULL)
      end

      # ---------- Linux Secret Service ----------
      def linux_secret_service_store(token, user)
        payload = { token: token, user: user }.to_json
        # secret-tool stores secrets per label/attributes
        Open3.capture3("secret-tool", "store", "--label=Vkit Token", "service", SERVICE, "account", ACCOUNT, stdin_data: payload)
      end

      def linux_secret_service_load
        stdout, _stderr, status = Open3.capture3("secret-tool", "lookup", "service", SERVICE, "account", ACCOUNT)
        return nil unless status.success?
        JSON.parse(stdout)
      rescue
        nil
      end

      def linux_secret_service_delete
        # secret-tool has no direct delete; overwrite with empty or rely on keyring tools
        # Fallback to storing blank
        linux_secret_service_store("", {})
      end

      # ---------- File fallback (0600) ----------
      def file_store(token, user)
        dir = File.dirname(@fallback_path)
        FileUtils.mkdir_p(dir)
        unless File.exist?(@fallback_path)
          File.write(@fallback_path, "{}")
          File.chmod(0o600, @fallback_path)
        end
        data = { "token" => token, "user" => user }
        File.write(@fallback_path, JSON.pretty_generate(data))
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
