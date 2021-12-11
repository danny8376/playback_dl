require "lexbor"
require "json"
require "uri"
require "shell-escape"

require "./downloader"

class YTDownloader < Downloader
  class NotSupportedError < ::Exception
    def self.new
      new(message: "Not supported video, maybe not stream, use youtube-dl to download instead.")
    end
  end

  YT = URI.parse "https://www.youtube.com"

  TYPES = %w{video audio}

  @video_file : File?
  @audio_file : File?

  def initialize(@id : String, @auto_merge : Bool? = nil, @merge = false, @no_resume = false, @auth_token = "", @cookies = "")
    super @auto_merge, @merge, @no_resume, @auth_token, @cookies
    @title = ""
    @date = ""
    @video_url = ""
    @video_uri = URI.new
    @video_query = URI::Params.new
    @video_size = -1_i64
    @audio_url = ""
    @audio_uri = URI.new
    @audio_query = URI::Params.new
    @audio_size = -1_i64
    @resume_rewind = 0_i64
    @sq = 0
    @type = :video
    @fail = 0
    @streaming = true
  end

  {% for type in TYPES %}
    def set_{{type.id}}(@{{type.id}}_url, @{{type.id}}_size = -1_i64)
      @{{type.id}}_uri = URI.parse @{{type.id}}_url
      @{{type.id}}_query = @{{type.id}}_uri.query_params
    end
  {% end %}

  def load_resume_file
    @resume_file = File.open(tmp_name(:resume), "r+")
    @resume_file.try do |f|
      @streaming = f.gets.not_nil! == "stream"
      @title = f.gets.not_nil!
      @date = f.gets.not_nil!
      set_video f.gets.not_nil!
      set_audio f.gets.not_nil!
      @resume_rewind = f.pos
      open_tmp "ab"
      if @streaming
        @video_file.try &.pos = f.gets.not_nil!.to_i64
        @audio_file.try &.pos = f.gets.not_nil!.to_i64
        @sq = f.gets.not_nil!.to_i
      else
        @video_size = f.gets.not_nil!.to_i64
        @audio_size = f.gets.not_nil!.to_i64
      end
    end
    @resuming = true
    @resume_file
  rescue ex : NilAssertionError
    nil
  end

  def save_resume_file
    @resume_file.try do |f|
      f.pos = 0
      f.puts @streaming ? "stream" : "video"
      f.puts @title
      f.puts @date
      f.puts @video_url
      f.puts @audio_url
      f.flush
      @resume_rewind = f.pos
      if @streaming
        f.puts @video_file.try(&.pos) || 0
        f.puts @audio_file.try(&.pos) || 0
        f.puts @sq
      else
        f.puts @video_size
        f.puts @audio_size
      end
      f.flush
    end
  end

  def update_resume_file
    @resume_file.try do |f|
      f.pos = @resume_rewind
      f.puts @video_file.try(&.pos) || 0
      f.puts @audio_file.try(&.pos) || 0
      f.puts @sq
      f.flush
    end
  end

  def extract_url_from_format(format)
    if url = format["url"]?.try &.as_s
      url.not_nil!
    elsif sig_cipher = format["signatureCipher"]?.try &.as_s
      ""
    else
      ""
    end
  end

  def tmp_name(type : Symbol)
    case type
    when :video, :audio
      "dltmp-yt-#{type}-#{@id}.ts"
    when :resume
      "dltmp-yt-resume-#{@id}.dat"
    else
      ""
    end
  end

  def open_tmp(mode = "wb")
    @video_file = File.open(tmp_name(:video), mode)
    @audio_file = File.open(tmp_name(:audio), mode)
    @resume_file = File.open(tmp_name(:resume), mode) if @resume_file.nil?
  end

  def close_tmp
    @video_file.try &.close
    @audio_file.try &.close
    @resume_file.try &.close
  end

  def clean_tmp
    @video_file.try &.delete
    @audio_file.try &.delete
    @resume_file.try &.delete
  end

  def parse_video_web
    res = get YT, path: "/watch?v=#{@id}"
    if res.status_code != 200
      raise "Unable to retrieve chat basic info, HTTP #{res.status_code}"
      return
    end
    {% for type in TYPES %}
      {{type.id}}_url = ""
      {{type.id}}_bitrate = 0
      {{type.id}}_size = -1_i64
    {% end %}
    html = Lexbor::Parser.new res.body
    @date = Time.local.to_s("%Y%m%d") # fallback
    html.css("script:not([src])").each do |node|
      {% begin %}
        case node.inner_text
        when /var ytInitialPlayerResponse\s*=\s*({.*?});/
          json = JSON.parse $~[1]
          video_details = json["videoDetails"]
          @title = video_details["title"].as_s
          microformat = json["microformat"]["playerMicroformatRenderer"]
          if video_details["isLive"]?.try &.as_bool
            @date = Time.parse_rfc3339(microformat["liveBroadcastDetails"]["startTimestamp"].as_s).to_s("%Y%m%d")
          else
            @date = microformat["uploadDate"].as_s.gsub("-") {}
          end
          formats = json["streamingData"]["adaptiveFormats"].as_a
          formats.each do |format|
            case format["mimeType"].as_s
            {% for type in TYPES %}
              when .starts_with? "{{type.id}}"
                bitrate = format["bitrate"].as_i
                if bitrate > {{type.id}}_bitrate
                  url = extract_url_from_format format
                  unless url.empty?
                    size = format["contentLength"]?.try &.as_s
                    unless size.nil?
                      @streaming = false
                      {{type.id}}_size = size.not_nil!.to_i64
                    end
                    {{type.id}}_bitrate = bitrate
                    {{type.id}}_url = url
                  end
                end
            {% end %}
            end
          end
        end
      {% end %}
    end
    {% for type in TYPES %}
      raise NotSupportedError.new if {{type.id}}_url.empty?
      set_{{type.id}} {{type.id}}_url, {{type.id}}_size
    {% end %}
  end

  def dl_segment
    {% begin %}
      case @type
      {% for type in TYPES %}
        when :{{type.id}}
          file = @{{type.id}}_file.not_nil!
          @{{type.id}}_query["sq"] = @sq.to_s
          @{{type.id}}_uri.query_params = @{{type.id}}_query
          get @{{type.id}}_uri do |res|
            fail = true
            puts "Getting {{type.id}}-#{@sq}.ts"
            case res.status_code
            when 200
              prev_pos = file.pos
              begin
                IO.copy res.body_io, file
                file.flush
                puts "{{type.id}}-#{@sq}.ts done"
                step
                fail = false
              rescue ex : IO::Error
                file.pos = prev_pos
              end
            else
              res.body_io?.try &.skip_to_end # consume remaining body
            end

            if fail
              puts "Retrieving {{type.id}}-#{@sq}.ts failed, retry #{@fail}/30"
              sleep 1.second
              @fail += 1
              if @fail > 30
                raise "failed - maybe normal if last file downloaded"
              end
            end
          end
      {% end %}
      end
    {% end %}
  end

  def step
    @fail = 0
    case @type
    when :video
      @type = :audio
    when :audio
      @type = :video
      @sq += 1
      update_resume_file
    end
  end

  def dl_single
    channel = Channel(Nil).new
    {% for type in TYPES %}
      spawn do
        file = @{{type.id}}_file.not_nil!
        if @resuming
          file.seek(0, IO::Seek::End)
          @{{type.id}}_query["range"] = "#{file.pos}-"
          @{{type.id}}_uri.query_params = @{{type.id}}_query
        end
        total = @{{type.id}}_size
        last = current = start = file.pos
        puts "Retrieving {{type.id}}, #{current.humanize_bytes} of #{total.humanize_bytes}"
        get @{{type.id}}_uri, :{{type.id}} do |res|
          io = res.body_io
          buffer = uninitialized UInt8[4096]
          time = Time.monotonic
          while (len = io.read(buffer.to_slice).to_i32) > 0
            file.write buffer.to_slice[0, len]
            current &+= len
            if current - last > 1048576_i64
              last = current
              speed = ((current - start) / (Time.monotonic - time).total_seconds).round.to_i64
              puts "Retrieving {{type.id}}, #{current.humanize_bytes} of #{total.humanize_bytes}, #{speed.humanize_bytes}/s"
            end
            Fiber.yield
          end
          channel.send nil
        end
      end
    {% end %}
    {{TYPES.size}}.times { channel.receive }
  end

  def filename
    "#{sanitize_filename @date}-#{sanitize_filename @title}-#{@id}.mp4"
  end

  def merge
    `ffmpeg -i #{tmp_name(:video)} -i #{tmp_name(:audio)} -c copy #{Process.quote filename}`
    if $?.success?
      clean_tmp
    end
  end

  def dl
    if @no_resume
      parse_video_web
      open_tmp
    elsif !File.exists?(tmp_name(:resume)) || load_resume_file.nil?
      parse_video_web
      open_tmp
      save_resume_file
    end
    puts "start downloading youtube #{@id}"
    if @streaming
      loop do
        dl_segment
      end
    else
      dl_single
    end
  ensure
    close_tmp
    merge if @auto_merge.nil? ? !@streaming : @auto_merge
  end
end

