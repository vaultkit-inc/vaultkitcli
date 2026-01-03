module Vkit
  module CLI
    class RequestsCLI < Thor
      desc "list", "List your past requests"
      option :state,
             type: :string,
             default: "all",
             enum: %w[all pending approved denied]

      option :format,
             type: :string,
             default: "table",
             enum: %w[json table]

      def list
        Commands::RequestsListCommand.new(
          api_url: ENV["VKIT_API_URL"]
        ).call(
          state: options[:state],
          format: options[:format]
        )
      end
    end
  end
end
