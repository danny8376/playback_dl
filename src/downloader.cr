require "http/client"
require "uri"

class Downloader
  @resume_file : File?

  def initialize(@auto_merge : Bool? = nil, @merge = false, @no_resume = false)
    @clients = Hash(Tuple(Symbol, String), HTTP::Client).new
    @resuming = false
  end

  def client(uri : URI, type = :main)
    host = uri.host.not_nil!
    key = {type, host}
    client = @clients[key]?
    if client.nil?
      client = HTTP::Client.new host, tls: true
      @clients[key] = client
    end
    client.not_nil!
  end

  def exec(method : String, uri : URI, type = :main, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil, depth = 0, &block : HTTP::Client::Response -> )
    depth += 1
    raise "too many redirection" if depth > 15
    client(uri, type).exec method, uri.request_target, headers, body do |res|
      case res.status_code
      when 301, 302
        puts "Redirection"
        exec method, URI.parse(res.headers["Location"]), type, headers, body, depth, &block
      else
        yield res
      end
    end
  end

  {% for method in %w(get post) %}
    def {{method.id}}(uri : URI, type = :main, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil, &block : HTTP::Client::Response -> )
      exec {{method.upcase}}, uri, type, headers, body, &block
    end
  {% end %}

  def sanitize_filename(s)
    s.gsub(/(?:[\/<>:"\|\\?\*]|[\s.]$)/) { "#" }
  end

  def load_resume_file
    nil
  end

  def merge
  end

  def dl
  end

  def run
    if @merge
      merge if load_resume_file
    else
      dl
    end
  end
end

