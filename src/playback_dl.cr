require "option_parser"

require "./downloader/*"

target = ""
auto_merge : Bool? = nil
merge = false
no_resume = false
auth_token = ""
cookies = ""

OptionParser.parse do |parser|
  parser.banner = "Usage: playback_dl [arguments] URL"
  parser.on("-a", "--auto-merge", "Auto merge into single mp4 after download (default false for streaming, true for video)") { auto_merge = true }
  parser.on("-A", "--disable-auto-merge", "disable auto merge (above)") { auto_merge = false }
  parser.on("-c", "--cookies=COOKIES", "HTTP Authorization header") { |v| cookies = v }
  parser.on("-h", "--help", "Show this help") { puts parser ; exit }
  parser.on("-m", "--merge", "merge mode") { merge = true }
  parser.on("-t", "--auth-token=TOKEN", "HTTP Authorization header") { |v| auth_token = v }
  parser.on("-R", "--disable-resume", "don't try to resume") { no_resume = true }
  parser.unknown_args do |args|
    target = args.first
  end
end

uri = URI.parse target
query = uri.query_params

dl = nil
case uri.host
when "www.youtube.com"
  dl = YTDownloader.new query["v"], auto_merge: auto_merge, merge: merge, no_resume: no_resume, auth_token: auth_token, cookies: cookies
when "youtu.be"
  _, id = uri.path.split "/"
  dl = YTDownloader.new id, auto_merge: auto_merge, merge: merge, no_resume: no_resume, auth_token: auth_token, cookies: cookies
when "www.twitch.tv", "twitch.tv"
  path = uri.path.split "/"
  _, ch, id = path
  if path.size == 2 # channel
  elsif ch == "videos"
    dl = TwitchVodDownloader.new id, auto_merge: auto_merge, merge: merge, no_resume: no_resume, auth_token: auth_token, cookies: cookies
  end
end

dl.try &.run
