# core/jwt_encoder.rb
require "jwt"
require "openssl"

module Vkit
  module Core
    class JwtEncoder
      PRIVATE_KEY_PATH = ENV["VKIT_PRIVATE_KEY"]

      def self.private_key
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
