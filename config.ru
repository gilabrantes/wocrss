require 'rubygems'
require "net/http"
require "net/https"
require 'uri'
require "yaml"
require 'hpricot'
require "rss/maker"
require 'rack'
require 'thread'
require 'sqlite3'
require 'monitor.rb'
require "wocrss.rb"


#Rack application
run WocRssApplication.new