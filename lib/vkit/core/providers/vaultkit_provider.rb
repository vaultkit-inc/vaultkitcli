module Vkit
  module Core
    module Providers
      class VaultKitProvider
        def resolve(ds)
          {
            "engine"   => ds[:engine],
            "host"     => ds[:config]["host"],
            "port"     => ds[:config]["port"],
            "database" => ds[:config]["database"],
            "username" => ds[:username],   # decrypted by DatasourceStore
            "password" => ds[:password]    # decrypted by DatasourceStore
          }
        end
      end
    end
  end
end
