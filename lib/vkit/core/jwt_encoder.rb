# core/jwt_encoder.rb
require "jwt"
require "openssl"

module Vkit
  module Core
    class JwtEncoder
      PRIVATE_KEY_PATH = ENV["VKIT_PRIVATE_KEY"]

      def self.private_key
        raise "Missing VKIT_PRIVATE_KEY env var" unless PRIVATE_KEY_PATH
        raise "Private key not found: #{PRIVATE_KEY_PATH}" unless File.exist?(PRIVATE_KEY_PATH)

        OpenSSL::PKey::RSA.new(File.read(PRIVATE_KEY_PATH))
      end

      def self.issue_session_token(user:, grant_id:, expires_at:)
        payload = {
          sub: user,
          grant: grant_id,
          exp: expires_at.to_i
        }

        JWT.encode(payload, private_key, "RS256")
      end
    end
  end
end
