module Vkit
  module CLI
    module Commands
      class ResetCommand < BaseCommand
        def call
          print "⚠️  This will clear all stored credentials. Continue? (y/N): "
          response = $stdin.gets.chomp
          
          unless response.downcase == 'y'
            puts "Cancelled"
            return
          end

          credential_store.clear!
          puts "🧹 All credentials cleared"
        end
      end
    end
  end
end