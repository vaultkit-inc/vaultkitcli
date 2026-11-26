module Vkit
  module CLI
    module Commands
      class ResetCommand < BaseCommand
        def call(yes: false)
          unless yes
            confirmation_needed!("Clearing all stored credentials", "--yes") if json?

            print "⚠️  This will clear all stored credentials. Continue? (y/N): "
            response = $stdin.gets.to_s.chomp

            unless response.downcase == 'y'
              puts "Cancelled"
              return
            end
          end

          credential_store.clear!
          puts "🧹 All credentials cleared"
          respond({ "cleared" => true }, ["vkit login"])
        end
      end
    end
  end
end