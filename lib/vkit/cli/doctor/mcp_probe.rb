# frozen_string_literal: true

require "json"
require "io/wait"
require "open3"
require_relative "../../version"

module Vkit
  module CLI
    module Doctor
      # Starts an MCP server over stdio, asks for its tools (initialize,
      # then tools/list), and stops it. Returns the tool names; raises
      # Failed when it doesn't start, answer or list in time.
      class McpProbe
        class Failed < StandardError; end

        PROTOCOL_VERSION = "2025-06-18"

        def initialize(timeout: 20)
          @timeout = timeout
        end

        def call(command, env)
          secret = env["VAULTKIT_TOKEN"].to_s
          stdin, stdout, stderr, wait = Open3.popen3(env, command)
          errors = Thread.new { stderr.read.to_s rescue "" } # rubocop:disable Style/RescueModifier
          deadline = now + @timeout

          send_message(stdin, id: 1, method: "initialize",
                              params: { protocolVersion: PROTOCOL_VERSION, capabilities: {},
                                        clientInfo: { name: "vkit-doctor", version: Vkit::VERSION } })
          reply(stdout, 1, deadline)
          send_message(stdin, method: "notifications/initialized")
          send_message(stdin, id: 2, method: "tools/list", params: {})
          Array(reply(stdout, 2, deadline).dig("result", "tools")).map { |t| t["name"] }.compact
        rescue Failed => e
          raise Failed, scrub(with_stderr(e.message, errors, wait), secret)
        rescue SystemCallError, IOError => e
          raise Failed, scrub(with_stderr(e.message, errors, wait), secret)
        ensure
          stop(stdin, wait)
        end

        private

        def send_message(io, **message)
          io.puts(JSON.generate({ jsonrpc: "2.0" }.merge(message)))
          io.flush
        end

        # The response with this id, skipping notifications and log lines.
        def reply(io, id, deadline)
          buffer = +""
          loop do
            left = deadline - now
            raise Failed, "no answer within #{@timeout}s" if left <= 0
            raise Failed, "no answer within #{@timeout}s" unless io.wait_readable(left)

            chunk = io.read_nonblock(4096, exception: false)
            raise Failed, "it exited before answering" if chunk.nil?
            next if chunk == :wait_readable

            buffer << chunk
            while (line = buffer.slice!(/\A[^\n]*\n/))
              message = JSON.parse(line) rescue next # rubocop:disable Style/RescueModifier
              next unless message.is_a?(Hash) && message["id"] == id
              raise Failed, message.dig("error", "message").to_s if message["error"]

              return message
            end
          end
        end

        def with_stderr(message, errors, wait)
          return message unless errors

          stop_process(wait)
          last = errors.join(2)&.value.to_s.lines.map(&:strip).reject(&:empty?).last
          last ? "#{message} (#{last})" : message
        end

        def stop(stdin, wait)
          stdin&.close unless stdin&.closed?
          stop_process(wait)
        rescue IOError
          nil
        end

        def stop_process(wait)
          return unless wait&.alive?

          Process.kill("TERM", wait.pid)
          Process.kill("KILL", wait.pid) unless wait.join(2)
        rescue Errno::ESRCH
          nil
        end

        def scrub(text, secret)
          secret.length >= 4 ? text.gsub(secret, "[REDACTED]") : text
        end

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
