require_relative "providers/vaultkit_provider"

module Vkit
  module Core
    class CredentialResolver
      def initialize(datasource_store: DatasourceStore.new)
        @store = datasource_store
      end

      # Main entry point
      def resolve(datasource_id)
        ds = @store.fetch(datasource_id)
        raise "Unknown datasource: #{datasource_id}" unless ds

        provider = provider_for(ds[:provider] || "vaultkit")
        provider.resolve(ds)
      end

      private

      def provider_for(name)
        case name
        when "vaultkit"
          Providers::VaultKitProvider.new
        when "aws"
          Providers::AwsSecretsProvider.new
        when "gcp"
          Providers::GcpSecretManagerProvider.new
        when "azure"
          Providers::AzureKeyVaultProvider.new
        else
          raise "Unknown credential provider: #{name}"
        end
      end
    end
  end
end
