require_relative "commands/base_command"

Dir[File.join(__dir__, "commands", "*.rb")].each do |file|
  require_relative file.sub("#{__dir__}/", "")
end