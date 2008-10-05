require 'rubygems'
require "net/http"
require "net/https"
require "yaml"
require 'hpricot'
require "rss/maker"
require 'rack'
require 'thread'
require 'sqlite3'
require 'monitor.rb'
require "wocrss.rb"


#Config file is loaded
CONFIG = YAML.load(File.open("wocrss.yml"))
COURSES = CONFIG["courses"]
YEARS = CONFIG["years"]


#Rack application
app = proc do |env|
	#setup cache
	#extract path to use as parameters
	path_bits = env["REQUEST_PATH"].split("/")
	
	#translate parameters to year_id and course_id
	if path_bits.size == 3
		year_id = translate_year(path_bits[1])
		course_id = translate_course(path_bits[2])
	end
	
	#Serve xml feed, error or static file
	if path_bits[1] == "mirror"
		[200, { 'Content-Type' => 'application/xhtml+xml' }, static_file_html]
	elsif path_bits[1].nil?
		[200, { 'Content-Type' => 'application/xhtml+xml' }, feed_list_html(env)]
	elsif not year_id.nil? and not course_id.nil?
			[200, { 'Content-Type' => 'application/xhtml+xml' }, @cache.cached_feed(course_id, year_id)]
	else
		[404, { 'Content-Type' => 'application/xhtml+xml'}, error_html]
	end
end

@cache = WoCFeedCache.new
run app