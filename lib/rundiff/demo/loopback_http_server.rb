require "socket"

module RunDiff
  module Demo
    class LoopbackHttpServer
      RESPONSE = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".freeze

      class << self
        def url
          start unless @server
          "http://127.0.0.1:#{@server.addr[1]}/ping"
        end

        private

        def start
          @server = TCPServer.new("127.0.0.1", 0)
          @thread = Thread.new do
            loop do
              client = @server.accept
              serve(client)
            end
          rescue IOError, Errno::EBADF
            nil
          end
          at_exit { stop }
        end

        def serve(client)
          while (line = client.gets)
            break if line == "\r\n"
          end
          client.write(RESPONSE)
        ensure
          client.close
        end

        def stop
          @server&.close
          @thread&.kill
        end
      end
    end
  end
end
