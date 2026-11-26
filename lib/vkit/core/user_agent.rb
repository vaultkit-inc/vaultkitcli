# frozen_string_literal: true

require "rbconfig"
require_relative "../version"

module Vkit
  module Core
    # The User-Agent on every request vkit makes, e.g.
    # "vkit/1.5.0 (macOS arm64; ruby 3.3.6)", so the console's setup-session
    # approval page (and the control plane's logs) show what asked, rather
    # than Net::HTTP's bare "Ruby".
    module UserAgent
      module_function

      def to_s
        @to_s ||= "vkit/#{Vkit::VERSION} (#{os_name} #{RbConfig::CONFIG['host_cpu']}; ruby #{RUBY_VERSION})"
      end

      def os_name(host_os = RbConfig::CONFIG["host_os"])
        case host_os
        when /darwin/ then "macOS"
        when /linux/ then "Linux"
        when /mswin|mingw|cygwin/ then "Windows"
        when /freebsd/ then "FreeBSD"
        else host_os
        end
      end
    end
  end
end
