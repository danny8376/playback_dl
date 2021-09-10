require "option_parser"

require "./yt_downloader"

target = ""
auto_merge : Bool? = nil
merge = false
no_resume = false

OptionParser.parse do |parser|
  parser.banner = "Usage: playback_dl [arguments] URL"
  parser.on("-a", "--auto-merge", "Auto merge into single mp4 after download (default false for streaming, true for video)") { auto_merge = true }
  parser.on("-A", "--disable-auto-merge", "disable auto merge (above)") { auto_merge = false }
  parser.on("-h", "--help", "Show this help") { puts parser ; exit }
  parser.on("-m", "--merge", "merge mode") { merge = true }
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
  dl = YTDownloader.new query["v"], auto_merge: auto_merge, merge: merge, no_resume: no_resume
when "youtu.be"
  _, id = uri.path.split "/"
  dl = YTDownloader.new id, auto_merge: auto_merge, merge: merge, no_resume: no_resume
end

dl.try &.run
