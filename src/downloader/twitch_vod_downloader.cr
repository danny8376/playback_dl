require "json"
require "uri"
require "m3u8"
require "shell-escape"

require "./downloader"

class TwitchVodDownloader < Downloader
  GQL = URI.parse "https://gql.twitch.tv/gql"
  USHER = URI.parse "https://usher.ttvnw.net"

  GQL_HEADERS = HTTP::Headers.new
  GQL_HEADERS["Client-ID"] = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  ACCESS_TOKEN_GQL = <<-GQLQUERY
    {
      %s(
        %s: "%s",
        params: {
          platform: "web",
          playerBackend: "mediaplayer",
          playerType: "site"
        }
      )
      {
        value
        signature
      }
    }
    GQLQUERY

  @video_file : File?
  @audio_file : File?

  def initialize(@id : String, @auto_merge : Bool? = nil, @merge = false, @no_resume = false, @auth_token = "", @cookies = "")
    super @auto_merge, @merge, @no_resume, @auth_token, @cookies
    @title = ""
    @date = ""
    @created_at = Time.local
    @type = ""
    @channel_name = ""
    @resume_rewind = 0_i64
    @seg_duration = 0.0
    @sq = 0
    @uri = USHER.dup
    @playlist = M3U8::Playlist.new
    @fail = 0
    @streaming = false
    @stream_id = ""
    @chasing = false
    unless @auth_token.empty?
      GQL_HEADERS["Authorization"] = @auth_token
    end
  end

  def gql(body)
    res = post GQL, headers: GQL_HEADERS, body: body
    if res.success?
      begin
        json = JSON.parse res.body
        return json["data"]
      rescue ex : JSON::ParseException | TypeCastError
      rescue
      end
    end
  end

  def access_token
    method = "videoPlaybackAccessToken"
    body = { "query" => ACCESS_TOKEN_GQL % {method, "id", @id} }.to_json
    begin
      return gql(body).not_nil![method].as_h.transform_values &.as_s
    rescue
    end
    raise "unable to get access token"
  end

  def live_info
    body = {
      "extensions" => {
        "persistedQuery" => {
          "sha256Hash" => "639d5f11bfb8bf3053b424d9ef650d04c4ebb7d94711d644afb08fe9a0fad5d9",
          "version": 1
        }
      },
      "operationName" => "UseLive",
      "variables" => {
        "channelLogin" => channel_name
      }
    }.to_json
    data = gql body
    raise "unable to get live info" if data.nil?
    stream = data["user"]["stream"]
    if stream.raw.nil?
      {nil, nil}
    else
      {stream["id"].as_s, Time.parse_rfc3339(stream["createdAt"].as_s)}
    end
  end

  def channel_name
    if @channel_name.empty?
      body = {
        "extensions" => {
          "persistedQuery" => {
            "version" => 1,
            "sha256Hash" => "cf1ccf6f5b94c94d662efec5223dfb260c9f8bf053239a76125a58118769e8e2"
          }
        },
        "operationName" => "ChannelVideoCore",
        "variables" => {
          "videoID" => @id
        }
      }.to_json
      data = gql body
      raise "unable to get video owner" if data.nil?
      @channel_name = data["video"]["owner"]["login"].as_s
    end
    @channel_name
  end

  def video_info
    if @title.empty?
      body = {
        "extensions" => {
          "persistedQuery" => {
            "version" => 1,
            "sha256Hash" => "cb3b1eb2f2d2b2f65b8389ba446ec521d76c3aa44f5424a1b1d235fe21eb4806"
          }
        },
        "operationName" => "VideoMetadata",
        "variables" => {
          "channelLogin": channel_name,
          "videoID": @id
        }
      }.to_json
      data = gql body
      raise "unable to get video info" if data.nil?
      video = data["video"]
      @title = video["title"].as_s
      @created_at = Time.parse_rfc3339(video["createdAt"].as_s)
      @date = @created_at.to_s("%Y%m%d")
      @type = video["broadcastType"].as_s
    end
    {@title, @date, @created_at, @type}
  end

  def usher(path : String)
    token = access_token
    @uri = USHER.dup
    @uri.path = path
    @uri.query_params = URI::Params.new({
      "allow_source" => ["true"],
      "token" => [token["value"]],
      "sig" => [token["signature"]]
    })
    res = get @uri
    puts "access denied, maybe it's required to login, pass oauth token" if res.status_code == 403
    raise "unable to get data from usher" if res.status_code != 200
    res.body
  end

  # live https://usher.ttvnw.net/api/channel/hls/<CH>.m3u8

  def retrieve_segment_url
    master_m3u8 = M3U8::Playlist.parse usher("/vod/#{@id}.m3u8")
    video_info = master_m3u8.items.find do |item|
      if item.is_a? M3U8::PlaylistItem
        plitem = item.as(M3U8::PlaylistItem)
        plitem.video == "chunked"
      end
    end
    raise "no chuncked video ???" if video_info.nil?
    @uri = @uri.resolve video_info.not_nil!.uri.not_nil!
  end

  def retrieve_playlist
    res = get @uri
    raise "unable to get chunked video" unless res.success?
    @playlist = M3U8::Playlist.parse res.body
    duration_nil = @playlist.items.first.duration
    raise "unexpected video segment, no duration info" if duration_nil.nil?
    @seg_duration = duration_nil.not_nil!
  end

  def retrieve_info
    video_info
    if @type == "ARCHIVE"
      stream_id, time = live_info
      @streaming = !time.nil? && @created_at >= time.not_nil!
      @stream_id = stream_id.not_nil! if @streaming
    end
    retrieve_segment_url
    retrieve_playlist
  end

  def check_still_live
    return false unless @streaming
    stream_id, _ = live_info
    @stream_id == stream_id
  end

  def load_resume_file
    @resume_file = File.open(tmp_name(:resume), "r+")
    @resume_file.try do |f|
      streaming = f.gets.not_nil!.split(" ")
      @streaming = streaming[0] == "DL-STREAM"
      @stream_id = streaming[1] if @streaming
      @title = f.gets.not_nil!
      @date = f.gets.not_nil!
      @uri = URI.parse f.gets.not_nil!
      @seg_duration = f.gets.not_nil!.to_f64
      @resume_rewind = f.pos
      open_tmp "ab"
      @video_file.try &.pos = f.gets.not_nil!.to_i64
      @sq = f.gets.not_nil!.to_i
    end
    @resuming = true
    retrieve_playlist
    if @streaming
      @streaming = check_still_live
      save_resume_file
    end
    @resume_file
  rescue ex : NilAssertionError
    nil
  end

  def save_resume_file
    @resume_file.try do |f|
      f.pos = 0
      f.puts @streaming ? "DL-STREAM #{@stream_id}" : @type
      f.puts @title
      f.puts @date
      f.puts @uri
      f.puts @seg_duration
      f.flush
      @resume_rewind = f.pos
      f.puts @video_file.try(&.pos) || 0
      f.puts @sq
      f.flush
    end
  end

  def update_resume_file
    @resume_file.try do |f|
      f.pos = @resume_rewind
      f.puts @video_file.try(&.pos) || 0
      f.puts @sq
      f.flush
    end
  end

  def tmp_name(type : Symbol)
    case type
    when :video
      "dltmp-twitch-vod-video-#{@id}.ts"
    when :resume
      "dltmp-twitch-vod-resume-#{@id}.dat"
    else
      ""
    end
  end

  def open_tmp(mode = "wb")
    @video_file = File.open(tmp_name(:video), mode)
    @resume_file = File.open(tmp_name(:resume), mode) if @resume_file.nil?
  end

  def close_tmp
    @video_file.try &.close
    @resume_file.try &.close
  end

  def clean_tmp
    @video_file.try &.delete
    @resume_file.try &.delete
  end

  def step
    @fail = 0
    @sq += 1
    update_resume_file
  end

  def dl_segment
    file = @video_file.not_nil!
    if @sq >= @playlist.items.size
      @uri = @uri.resolve "#{@sq}.ts"
    else
      @uri = @uri.resolve @playlist.items[@sq].segment.not_nil!
    end
    get @uri do |res|
      fail = true
      puts "Getting #{@sq}.ts"
      case res.status_code
      when 200
        prev_pos = file.pos
        begin
          IO.copy res.body_io, file
          file.flush
          puts "#{@sq}.ts done"
          step
          fail = false
        rescue ex : IO::Error
          file.pos = prev_pos
        end
      when 403 # should be no file => mark chasing stream
        unless @chasing
          @chasing = true
          puts "Waiting %.2f seconds for next segment" % {@seg_duration}
          sleep @seg_duration.seconds
        end

        res.body_io.gets_to_end # consume remaining body
      else
        res.body_io.gets_to_end # consume remaining body
      end

      if fail
        puts "Retrieving #{@sq}.ts failed, retry #{@fail}/30"
        sleep 1.second
        @fail += 1
        if @fail > 30
          raise "failed - maybe normal if last file downloaded"
        end
      end
    end
  end

  def filename
    "#{sanitize_filename @date}-#{sanitize_filename @title}-#{@id}.mp4"
  end

  def merge
    `ffmpeg -i #{tmp_name(:video)} -c copy #{ShellEscape.quote filename}`
    if $?.success?
      clean_tmp
    end
  end

  def dl
    if @no_resume
      retrieve_info
      open_tmp
    elsif !File.exists?(tmp_name(:resume)) || load_resume_file.nil?
      retrieve_info
      open_tmp
      save_resume_file
    end
    puts "start downloading twitch vod #{@id}"
    while @streaming || @sq < @playlist.items.size
      dl_segment
      if @streaming && @chasing && @fail == 0
        puts "Waiting %.2f seconds for next segment" % {@seg_duration}
        sleep @seg_duration.seconds
      end
    end
  ensure
    close_tmp
    merge if @auto_merge.nil? ? !@streaming : @auto_merge
  end
end

