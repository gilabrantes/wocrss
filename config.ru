require 'rubygems'
require "net/http"
require "net/https"
require "yaml"
require "hpricot"
require "rss/maker"
require 'rack'
require 'thread'
require 'sqlite3'
require 'monitor.rb'


#Config file is loaded
CONFIG = YAML.load(File.open("wocrss.yml"))
COURSES = CONFIG["courses"]
YEARS = CONFIG["years"]

run app