require 'rubygems'
require 'rake'
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


desc "Build or update a mirror of the files from all years and courses"
task :update_cache do
	
	cache = WoCFeedCache.new
	if cache.exist?
		puts "Updating cache..."
		cache.update_cache
		puts "done!"
	else
		puts "Building cache for the first time... go out for a walk this will take a while!"
		cache.build_cache
		puts "done!"
	end
end