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
CONFIG = YAML.load(File.open("woc2rss.yml"))
COURSES = CONFIG["courses"]
YEARS = CONFIG["years"]

#Represent a WoC file
#The file_id and file_type are the values used to download them from WoC
#Published_at is used to date the rss item
#Both description and sec_description (secondary description) are concatenated and used as description of the rss item
class WocFile
	attr_accessor :title, :description, :sec_description, :file_id, :file_type, :filename, :file_length, :published_at	
end

#WocWorker handles all the scrapping and information extraction from WoC.
class WocWorker
	
	attr_accessor :conn #HTTP connection
	
	def initialize(url)
		@cookies = Hash.new
		@conn = Net::HTTP.new(url, 443)
		@conn.use_ssl = true
		@conn.verify_mode = OpenSSL::SSL::VERIFY_NONE
	end
	
	#authenticate as username/password
	def login!(username, password)
		check_value = self.get_check_value
		login_data = "password=#{password}&username=#{username}&checkValue=#{check_value}"
		login_header = {
			"Cookie" => "JSESSIONID=#{@cookies['JSESSIONID']}",
			"Content-Type" => "application/x-www-form-urlencoded",
			"Content-Length" => (login_data.length).to_s
		}
		
		response = @conn.post("/weboncampus/2moduledefaultlogin.do", login_data, login_header)
		self.cookiesParser(response)
		unless Hpricot(response.body).at("input[@alt='Logout']").nil?
			return response.body
		else
			return false
		end
	end
	
	#Get all the items from "material" type of pages and returns an array of items
	#The valid values to list argument are "material" or "materialavaliation"
	#
	#NOTE: This should use an authenticated worker
	def get_generic_list(list, file_id, year_id)
		#https://www.dei.uc.pt/weboncampus/class/getxxx.do?idclass=419&idyear=6
		@materials = Array.new
		tmp = WocFile.new
		
  		response = self.auth_get("/weboncampus/class/get#{list}.do?idclass=#{file_id}&idyear=#{year_id}")
		doc = Hpricot(response.body).search("td[@class='contentcell]")[1].search("table")[3].search("td").each do |td|
	   		case td.inner_html.strip
 	   		when /^&nbsp;$/
	   			next
 	   		when /<strong>.*<\/strong>$/
	   			#title
				#puts 1
	   			tmp = WocFile.new
	   			tmp.title = td.inner_html.match(/<strong>(.*)<\/strong>/)[1]
	   		when /<strong>Tema: <\/strong>(.*)/
	   			#description
		   		#puts 2
				desc = td.inner_html.match(/\s*<strong>Tema: <\/strong>\s*(.*)\s*/)[1]
	   			tmp.description = desc
   	   		when /.*<a href=.*/
	   			#download_link
	   			#puts 4
	   			download_link = td.inner_html.match(/.*<a href="(.*)"(.|\n)*/)[1]
	   			link_bits = download_link.match(/\/weboncampus\/getFile.do\?tipo=(\d*)&id=(\d*)/)
	   			tmp.file_type = link_bits[1]
	   			tmp.file_id = link_bits[2]
	   			date = td.inner_html.match(/(\d{4}-\d{2}-\d{2})/)[1]
	   			tmp.published_at = date
   	   			@materials << tmp
	   		else
	   			#sec_description
	   			#puts 3
	   			tmp.sec_description = td.inner_html.strip
 	   		end
 	   	end
		return @materials
	rescue
		return @materials
	end
	
	#Get all the items in the projects section and returns an array of projects
	#
	#NOTE: This should use an authenticated worker
	def get_projects_list(class_id, year_id)
		#https://www.dei.uc.pt/weboncampus/class/getprojects.do?idclass=419&idyear=6
		@projects = Array.new
		tmp = WocFile.new
		response = self.auth_get("/weboncampus/class/getprojects.do?idclass=#{class_id}&idyear=#{year_id}")
		doc = Hpricot(response.body).search("td[@class='contentcell]")[1].search("table")[1].search("td").each do |td|
			case td.inner_html
			when /^\s*<strong>.*<\/strong>\s*$/
				#title
				tmp = WocFile.new
				tmp.title = td.inner_html.match(/<strong>(.*)<\/strong>/)[1]
			when /\s*<table(.|\n)*/
				next
		    when />\d{4}-\d{2}-\d{2}</
		    	date = td.inner_html.match(/(\d{4}-\d{2}-\d{2})/)[1]
		    	tmp.published_at = date
		    	next
			when /.*<a href=(.|\n)*/
				download_link = td.inner_html.match(/.*<a href="(.*)"(.|\n)*/)[1]
				link_bits = download_link.match(/\/weboncampus\/getFile.do\?tipo=(\d*)&id=(\d*)/)
				tmp.file_type = link_bits[1]
				tmp.file_id = link_bits[2]
				@projects << tmp
				next
			when /^&nbsp;$/
				next
			when /\s*(<span)|(<b>)|(<font)(.|\n).*/
				next
			else
				#sec_description
				tmp.description = td.inner_html.strip
			end
		end
		return @projects
	rescue
		return @projects
	end
	
	#Get the file by file_id and file_type and returns an array containing filename, file length, and file data
	#
	#NOTE: This should use an authenticated worker
	def get_file(file_id, file_type)
		response = self.auth_get("/weboncampus/getFile.do?tipo=#{file_type}&id=#{file_id}")
		filename = response["content-disposition"].match(/filename="(.*)"/)[1]
		length = response["Content-Length"]
		return filename, length, response.body
	end
	
	protected
	
	#Does a authenticated get
	def auth_get(path)
		header = {
			"Cookie" => "JSESSIONID=#{@cookies['JSESSIONID']}",
		}
		return @conn.get(path, header)
	end
	
	#Gets the stupid check_value needed for authentication
	def get_check_value
		response = @conn.get("/weboncampus/")
		self.cookiesParser(response)
		check_value = Hpricot(response.body).at("form[@name='formLogin']").at("input[@name='checkValue']").get_attribute("value")
		return check_value
	end

	#Parses the cookies
	def cookiesParser(header)
		unless header['set-cookie'].nil?
			cookies = header['set-cookie'].split(";")
			cookies.each do |c|
				d = c.split(",")
				d.each do |e|
					e.strip
					f = e.split(%r{=(.*)}m) if e.include?("=") and !e.include?("EXPIRED") and !e.include?("adwords") and !e.include?("Expires") and !e.include?("Path") and !e.include?("Domain")
					if !f.nil? and !f[0].nil? and !f[1].nil?
						g = f[0]
						h = f[1]
						@cookies[g.strip] = h.strip
					end
				end
			end
		end
	end
end

#MirrorWorkers check if the file is already mirrored, if not mirror them
class MirrorWorker
	
	def initialize
		@download_retries = CONFIG["download_retries"]
		@mirror_path = CONFIG["mirror_path"]
		@db = SQLite3::Database.open(CONFIG["db_filename"])
		@woc_worker = WocWorker.new(CONFIG["url"])
		@woc_worker.login!(CONFIG["username"], CONFIG["password"])
	end
	
	#Mirror the file locally
	def mirror_file(woc_file)
		#download the file
		begin
			file_data = @woc_worker.get_file(woc_file.file_id, woc_file.file_type)
			file_data << woc_file.published_at
		rescue
			@download_retries -= 1
			retry unless @download_retries >= 0
		end
		new_file = File.new("#{@mirror_path}/#{file_data[0]}", 'w')
		new_file.write(file_data[2])
		new_file.close
		
		#insert db entry
		@db.execute("INSERT INTO mirror_files (file_id, file_type, filename, length, published_at) VALUES ('#{woc_file.file_id}','#{woc_file.file_type}','#{file_data[0]}','#{file_data[1]}','#{woc_file.published_at}')")
		
		return file_data		
	end
	
	#Checks if the file is mirrored, and mirror in case that its not.
	#Returns an array containing filename, file length and pucliched_at
	def mirror_filename(woc_file)
		file_row = @db.get_first_row("SELECT filename, length, published_at FROM mirror_files WHERE file_type = '#{woc_file.file_type}' AND file_id = '#{woc_file.file_id}'")
		if file_row.nil?
			file_row = self.mirror_file(woc_file)
			return file_row
		else
			return file_row 
		end
	end
	
end

#Build the rss feed
class WocRssBuilder
	
	attr_reader :cached_rss
	
	def initialize(course_id, year_id)
		#puts "GO!"
		@course_id = course_id
		@year_id = year_id
		@worker_num = CONFIG["mirror_workers"]
		@missing_workers = @worker_num
		#woc queue
		@woc_items = Array.new #This will store the items coming from WocWorkers so since it's a shared resource, must be synchronized
		@woc_mutex = Mutex.new
		@missing_producers = 3 #projects, material and avaliation material
		@producers_mutex = Mutex.new
		@producers_cv = ConditionVariable.new
		@workers_mutex = Mutex.new
		@workers_cv = ConditionVariable.new
		#mirror queue
		@mirror_items = Array.new #needs to be synchronized when mirror workers are producing items
		@mirror_mutex = Mutex.new
		#worker instances
		@mirror_workers = Array.new
		@woc_workers = Array.new
		#update cache!
		cached_rss
	end
	
	def build_rss
		#spawn one thread to download the material avaliation items
		@woc_workers << Thread.new do
			woc_worker = WocWorker.new(CONFIG['url'])
			woc_worker.login!(CONFIG['username'], CONFIG['password'])
			items = woc_worker.get_generic_list("materialavaliation", @course_id, @year_id)
			@woc_mutex.synchronize {
				@woc_items += items
			}
			@producers_mutex.synchronize {
				@missing_producers -= 1
				@producers_cv.signal
			}
		end
		
		#spawn one thread to download the material items
		@woc_workers << Thread.new do
			woc_worker = WocWorker.new(CONFIG['url'])
			woc_worker.login!(CONFIG['username'], CONFIG['password'])
			items = woc_worker.get_generic_list("material", @course_id, @year_id)
			@woc_mutex.synchronize {
				@woc_items += items
			}
			@producers_mutex.synchronize {
				@missing_producers -= 1
				@producers_cv.signal
			}
		end
		
		#spawn one thread to download the project items
		@woc_workers << Thread.new do
			woc_worker = WocWorker.new(CONFIG['url'])
			woc_worker.login!(CONFIG['username'], CONFIG['password'])
			items = woc_worker.get_projects_list(@course_id, @year_id)
			@woc_mutex.synchronize {
				@woc_items += items
			}
			@producers_mutex.synchronize {
				@missing_producers -= 1
				@producers_cv.signal
			}
		end
		
		#wait for all resources to finish
		@producers_mutex.synchronize {
			while @missing_producers > 0 do
				@producers_cv.wait(@producers_mutex)
			end
		}

		#spawn worker_num threads to mirror the woc items
		#they take items from @woc_items, check if the files are already mirrored or if they need to be mirrored and put the
		#mirrored item in @mirror_items array
		@worker_num.times do
			@mirror_workers << Thread.new(MirrorWorker.new) do |mirror_worker|
			begin
				items_num = 0
				
				#get items missing
				@woc_mutex.synchronize {
					items_num = @woc_items.size
				}
				
				#threads die when all resources were consumed
				while items_num > 0 do
					
					#take one item from @woc_items
					@woc_mutex.synchronize {
						@item = @woc_items.pop
					}
					
					#mirror the item and set the fields related to the mirroring
					file_row = mirror_worker.mirror_filename(@item)
					@item.filename = file_row[0]
					@item.file_length = file_row[1]
					
					#put that item in @mirror_items for later treatment
					@mirror_mutex.synchronize {
						@mirror_items << @item
					}
					
					#update items_num
					@woc_mutex.synchronize {
						items_num = @woc_items.size
					}
				end
				#There are no more items, this thread's work is done, send signal!
				@workers_mutex.synchronize {
					@missing_workers -= 1
					@workers_cv.signal
				}
			rescue
				abort [$!.inspect, $!.message, $!.backtrace].flatten.join("\n")
			end
			
			end
		end
		
		#wait for all mirror workers to finish their jobs before building the xml
		@workers_mutex.synchronize {
			while @missing_workers > 0 do
				@workers_cv.wait(@workers_mutex)
			end
		}
		
		#build the rss feed
  		version = "2.0"
  		content = RSS::Maker.make(version) do |m|
  			m.channel.title = CONFIG["course_names"][@course_id]
  			m.channel.link = "https://woc.dei.uc.pt/weboncampus/class/getpresentation.do?idclass=#{@course_id}"
  			m.channel.description = "Scrapped #{CONFIG['course_names'][@course_id]} feed"
  			m.items.do_sort = true
  	
			puts "array size #{@mirror_items.size}"
		
				#for each item in @mirror_items, grab one and add it to the feed
				while @mirror_items.size > 0 do
  					item = @mirror_items.pop
  			
  				   ################DEBUG!##################
				   # $ITEMS +=1
				   # puts "--------------------ITEM #{$ITEMS}-----------------"
  				   # puts "title: #{item.title}"
				   # puts "link: https://woc.dei.uc.pt/weboncampus/class/getpresentation.do?idclass=#{@course_id}"
				   # puts "enc_url: http://#{CONFIG['mirror_host']}/#{item.filename}"
				   # puts "end_length: #{item.file_length.to_s}"
				   # puts "date: #{item.published_at}"
				   # puts "-----------------------------------------------------"
				   #######################################
  					
					#build the item
  					i = m.items.new_item
  					i.title = item.title

					#arrange description
					composed_description = "#{item.description}<br/>" || ""
					composed_description += item.sec_description || ""
  					i.description = composed_description
  					
					i.link = "https://woc.dei.uc.pt/weboncampus/class/getpresentation.do?idclass=#{@course_id}"
  					
					#enclosure stuff
					i.enclosure.url = "http://#{CONFIG['mirror_host']}/#{item.filename}"
  					i.enclosure.length = item.file_length.to_s
  					i.enclosure.type = "application/octet-stream"
  					unless item.published_at.nil?
  						i.date = Time.parse(item.published_at)
  					else
  						i.date = Time.now
  					end
  				end
		
		end
		#DEBUG
		#puts content
		#puts "ITEMS -> #{$ITEMS}"
		#$ITEMS = 0
		return content.to_s
	end
	
	def cached_rss
		@cached_rss ||= build_rss
	end
	
end

class WoCFeedCache
	
	def initialize
		@builders = Hash.new
		build_cache
		start_cache_renew_job
	end
	
	def build_cache
		for year in CONFIG["years"]
			@builders[year[1]] = Hash.new
			for course in CONFIG["courses"]
				@builders[year[1]][course[1]] = WocRssBuilder.new(course[1], year[1])
			end
		end
	end
	
	def cached_feed(course_id, year_id)
		@builders[year_id][course_id].cached_rss
	end
	
	private
	
	#spawn a thread that refreshes cache periodically
	def start_cache_renew_job
		Thread.new do
			loop do
				for year in @builders
					for course_builder in year
						course_builder.cached_rss #refreshes the cache for each builder
					end
				end
				sleep(CONFIG["cache_interval"]*60) #the cache is valid for this period of time
			end
		end
	end
	
end

#Translate year string to year_id or return nil if year string is invalid
def translate_year(year_string)
	if CONFIG["years"][year_string].nil?
		return nil
	else
		return CONFIG["years"][year_string]
	end
end

#Translate course string to course_id or return nil if course string is invalid
def translate_course(course_string)
	if CONFIG["courses"][course_string].nil?
		return nil
	else
		return CONFIG["courses"][course_string]
	end
end

#Create an html file containing all feeds available
def feed_list_html(env)
	page = ""
	page << '<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
		"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
		<html xmlns="http://www.w3.org/1999/xhtml"
		     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		     xsi:schemaLocation="http://www.w3.org/MarkUp/SCHEMA/xhtml11.xsd"
		     xml:lang="en" >
			<head>
				<title>WoC scrapped feed list for #{CONFIG["host"]}</title>
			</head>
			<body>'
			page << '<dl>'
			for year in CONFIG["years"] do
				page << "<dt>#{year[0]}:</dt>"
				page << '<dd>'
				page << '<dl>'
				for course in CONFIG["courses"] do
					page << "<dt>#{CONFIG["course_names"][course[1]]}</dt>"
					page << "<dd>"
					page << "<a href=\"http://#{env["HTTP_HOST"]}/#{year[0]}/#{course[0]}/rss.xml\">http://#{env["HTTP_HOST"]}/#{year[0]}/#{course[0]}/rss.xml</a>"
					page << "</dd>"
				end
				page << '</dl>'
				page << '</dd>'
			end
			page << '</dl>'
		page << 		
			'</body>
		</html>'
		return page
end

#404 html
def error_html
	page = ""
	page << '
		<?xml version="1.0" encoding="UTF-8"?>\n
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
		"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"> \n
		<html xmlns="http://www.w3.org/1999/xhtml"
		     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		     xsi:schemaLocation="http://www.w3.org/MarkUp/SCHEMA/xhtml11.xsd"
		     xml:lang="en" > \n
			<head>\n
				<title>WoC scrapped feed list for #{CONFIG["host"]}</title>\n
			</head>\n
			<body> You have requested something stupid, review your url and make sure that its correct' 		
		page << '</body>
		</html>'
end

#static file html
def static_file_html
	page = ""
	page << '
		<?xml version="1.0" encoding="UTF-8"?>\n
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
		"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd"> \n
		<html xmlns="http://www.w3.org/1999/xhtml"
		     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
		     xsi:schemaLocation="http://www.w3.org/MarkUp/SCHEMA/xhtml11.xsd"
		     xml:lang="en" > \n
			<head>\n
				<title>WoC scrapped feed list for #{CONFIG["host"]}</title>\n
			</head>\n
			<body>static file!'		
		page <<'</body>
		</html>'
end

#Rack application
app = proc do |env|
	
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
#setup cache
@cache = WoCFeedCache.new
#setup rack
Rack::Handler::Mongrel.run(app, :Port => 3000)

###################DEBUG################
#$ITEMS = 0
#@worker = WocWorker.new(CONFIG['url'])
#@worker.login!(CONFIG['username'], CONFIG['password'])
#materialitems = Array.new
#materialavaitems = Array.new
#projects = Array.new
#materialitems = @worker.get_generic_list("material", "422", "5")
#materialavaitems += @worker.get_generic_list("materialavaliation", "422", "5")
#projects += @worker.get_projects_list("422", "5")
#
#puts "material"
#materialitems.each do |item|
#	puts item.title 
#end
#$ITEMS += materialitems.size
#puts materialitems.size
#puts ".----------------------------------"
#puts "meterial avaliacao"
#materialavaitems.each do |item|
#	puts item.title
#end
#$ITEMS += materialavaitems.size
#puts materialavaitems.size
#puts ".----------------------------------"
#puts "meterial avaliacao"
#projects.each do |item|
#	puts item.title
#end
#$ITEMS += projects.size
#	puts projects.size
#	
#puts "TOTAL #{$ITEMS}"
#########################################