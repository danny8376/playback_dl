require "http/client"
require "uri"

class Downloader
  @resume_file : File?

  def initialize(@auto_merge : Bool? = nil, @merge = false, @no_resume = false, @auth_token = "", @cookies = "")
    @clients = Hash(Tuple(Symbol, String, Int32), HTTP::Client).new do |h, k|
      type, host, num = k
      h[k] = HTTP::Client.new host, tls: true
    end
    @resuming = false
  end

  def client(uri : URI, type = :main, num = 0)
    @clients[{type, uri.host.not_nil!, num}]
  end

  def exec(method : String, uri : URI, type = :main, path = "", headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil, depth = 0, &block : HTTP::Client::Response -> )
    depth += 1
    raise "too many redirection" if depth > 15
    uri = uri.resolve path unless path.empty?
    client(uri, type).exec method, uri.request_target, headers, body do |res|
      case res.status_code
      when 301, 302
        puts "Redirection"
        exec method, URI.parse(res.headers["Location"]), type, path, headers, body, depth, &block
      else
        yield res
      end
    end
  end

  DUMMY_RES = HTTP::Client::Response.new 404
  {% for method in %w(get post) %}
    def {{method.id}}(uri : URI, type = :main, path = "", headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil)
      ret_res = DUMMY_RES
      exec {{method.upcase}}, uri, type, path, headers, body do |res|
        res.consume_body_io
        ret_res = res
      end
      ret_res
    end

    def {{method.id}}(uri : URI, type = :main, path = "", headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil, &block : HTTP::Client::Response -> )
      exec {{method.upcase}}, uri, type, path, headers, body, &block
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

