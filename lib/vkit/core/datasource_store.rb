require "sqlite3"
require "json"
require "securerandom"
require "openssl"
require "base64"

module Vkit
  module Core

    # AES-256-GCM Encryptor
    class Encryptor
      MASTER_KEY = ENV["VKIT_MASTER_KEY"] || ("0" * 64)

      def self.encrypt(plaintext)
        cipher = OpenSSL::Cipher::AES256.new(:gcm)
        cipher.encrypt
        cipher.key = [MASTER_KEY].pack("H*")
        iv = SecureRandom.random_bytes(12)
        cipher.iv = iv

        ciphertext = cipher.update(plaintext) + cipher.final
        tag = cipher.auth_tag

        Base64.strict_encode64(iv + tag + ciphertext)
      end

      def self.decrypt(encoded)
        raw = Base64.strict_decode64(encoded)
        iv = raw[0, 12]
        tag = raw[12, 16]
        ciphertext = raw[28..]

        cipher = OpenSSL::Cipher::AES256.new(:gcm)
        cipher.decrypt
        cipher.key = [MASTER_KEY].pack("H*")
        cipher.iv  = iv
        cipher.auth_tag = tag

        cipher.update(ciphertext) + cipher.final
      end
    end

    ######################################################################
    # DatasourceStore — MVP Version
    #
    # Stores datasource definitions:
    #
    #  id: "primary_pg"
    #  engine: "postgres"
    #  username: encrypted
    #  password: encrypted
    #  config: JSON (host, port, database, ssl)
    ######################################################################
    class DatasourceStore
      DEFAULT_PATH = "data/datasources.db"

      def initialize(path: DEFAULT_PATH)
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        create_table
      end

      # Create table
      def create_table
        @db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS datasources (
            id TEXT PRIMARY KEY,
            engine TEXT,
            username TEXT,          -- encrypted
            password TEXT,          -- encrypted
            config TEXT,            -- JSON: {"host": "...", "port": 5432, "database":"analytics"}
            created_at TEXT,
            updated_at TEXT
          );
        SQL

        @db.execute("CREATE INDEX IF NOT EXISTS idx_datasource_engine ON datasources(engine)")
      end

      ##################################################################
      # Create a datasource
      ##################################################################
      def add!(id:, engine:, username:, password:, config:)
        now = Time.now.utc.iso8601

        encrypted_username = Encryptor.encrypt(username.to_s)
        encrypted_password = Encryptor.encrypt(password.to_s)

        @db.execute(
          <<~SQL,
            INSERT INTO datasources (
              id, engine, username, password, config, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            id,
            engine,
            encrypted_username,
            encrypted_password,
            JSON.dump(config || {}),
            now,
            now
          ]
        )

        fetch(id)
      end

      ##################################################################
      # Update datasource
      ##################################################################
      def update!(id:, engine: nil, username: nil, password: nil, config: nil)
        ds = fetch(id)
        raise "Datasource #{id} not found" unless ds

        now = Time.now.utc.iso8601

        new_engine   = engine   || ds[:engine]
        new_username = username ? Encryptor.encrypt(username) : ds[:username_encrypted]
        new_password = password ? Encryptor.encrypt(password) : ds[:password_encrypted]
        new_config   = config   ? JSON.dump(config)          : JSON.dump(ds[:config])

        @db.execute(
          <<~SQL,
            UPDATE datasources
            SET engine=?, username=?, password=?, config=?, updated_at=?
            WHERE id=?
          SQL
          [
            new_engine,
            new_username,
            new_password,
            new_config,
            now,
            id
          ]
        )

        fetch(id)
      end

      ##################################################################
      # Fetch datasource
      ##################################################################
      def fetch(id)
        row = @db.get_first_row("SELECT * FROM datasources WHERE id=?", [id])
        return nil unless row
        to_hash(row)
      end

      # List all datasources
      def list
        @db.execute("SELECT * FROM datasources").map { |r| to_hash(r) }
      end

      # INTERNAL: Parse + decrypt
      def to_hash(row)
        decrypted_username = row["username"] ? Encryptor.decrypt(row["username"]) : nil
        decrypted_password = row["password"] ? Encryptor.decrypt(row["password"]) : nil

        {
          id:                   row["id"],
          engine:               row["engine"],
          username:             decrypted_username,
          password:             decrypted_password,
          username_encrypted:   row["username"],
          password_encrypted:   row["password"],
          config:               safe_parse_json(row["config"]),
          created_at:           row["created_at"],
          updated_at:           row["updated_at"]
        }
      end

      def safe_parse_json(val)
        return {} if val.nil? || val.strip.empty?
        JSON.parse(val)
      rescue
        {}
      end
    end

  end
end
