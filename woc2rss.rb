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

class WocFile
	
	attr_accessor :title, :description, :sec_description, :file_id, :file_type, :filename, :file_length, :published_at
	
end

class WocWorker
	
	attr_accessor :conn
	
	def initialize(url)
		@cookies = Hash.new
		@conn = Net::HTTP.new(url, 443)
		@conn.use_ssl = true
		@conn.verify_mode = OpenSSL::SSL::VERIFY_NONE
	end
	
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
	
	#returns filename and filecontent
	def get_file(file_id, file_type)
		response = self.auth_get("/weboncampus/getFile.do?tipo=#{file_type}&id=#{file_id}")
		filename = response["content-disposition"].match(/filename="(.*)"/)[1]
		length = response["Content-Length"]
		return filename, length, response.body
	end
	
	protected
	
	def auth_get(path)
		header = {
			"Cookie" => "JSESSIONID=#{@cookies['JSESSIONID']}",
		}
		return @conn.get(path, header)
	end
	
	
	def get_check_value
		response = @conn.get("/weboncampus/")
		self.cookiesParser(response)
		check_value = Hpricot(response.body).at("form[@name='formLogin']").at("input[@name='checkValue']").get_attribute("value")
		return check_value
	end

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


class MirrorWorker
	
	def initialize
		@download_retries = CONFIG["download_retries"]
		@mirror_path = CONFIG["mirror_path"]
		@db = SQLite3::Database.open(CONFIG["db_filename"])
		@woc_worker = WocWorker.new(CONFIG["url"])
		@woc_worker.login!(CONFIG["username"], CONFIG["password"])
	end
	
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


#CONFIG = YAML.load(File.open("#{ENV['HOME']}/.deisync.yml"))
CONFIG = YAML.load(File.open("woc2rss.yml"))

COURSES = CONFIG["courses"]
YEARS = CONFIG["years"]
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
#puts "meterial"
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
#	419 -> 39
# 	422 -> 27
class WocRssBuilder
	
	def initialize(course_id, year_id, env)
		#puts "GO!"
		@env = env
		@course_id = course_id
		@year_id = year_id
		@worker_num = CONFIG["mirror_workers"]
		@missing_workers = @worker_num
		#woc queue
		@woc_items = Array.new
		@woc_mutex = Mutex.new
		@missing_producers = 3 #projects, material and avaliation material
		@producers_mutex = Mutex.new
		@producers_cv = ConditionVariable.new
		@workers_mutex = Mutex.new
		@workers_cv = ConditionVariable.new
		#mirror queue
		@mirror_items = Array.new
		@mirror_mutex = Mutex.new
		#worker instances
		@mirror_workers = Array.new
		@woc_workers = Array.new
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
		
		#wait for all resources
		@producers_mutex.synchronize {
			while @missing_producers > 0 do
				@producers_cv.wait(@producers_mutex)
			end
		}

		#spawn worker_num threads to mirror the woc items
		@worker_num.times do
			@mirror_workers << Thread.new(MirrorWorker.new) do |mirror_worker|
			begin
				items_num = 0
				#threads die when all resources were consumed
				@woc_mutex.synchronize {
					items_num = @woc_items.size
				}
				
				while items_num > 0 do
					#puts "estou a espera do woc_mutex"
					@woc_mutex.synchronize {
						@item = @woc_items.pop
					}
					
					file_row = mirror_worker.mirror_filename(@item)
					@item.filename = file_row[0]
					@item.file_length = file_row[1]
					
					@mirror_mutex.synchronize {
						@mirror_items << @item
					}
					
					#update items_num
					@woc_mutex.synchronize {
						items_num = @woc_items.size
					}
				end
				@workers_mutex.synchronize {
					@missing_workers -= 1
					@workers_cv.signal
				}
			rescue
				abort [$!.inspect, $!.message, $!.backtrace].flatten.join("\n")
			end
			
			end
		end
		
		@workers_mutex.synchronize {
			while @missing_workers > 0 do
				@workers_cv.wait(@workers_mutex)
			end
		}
			
  		version = "2.0"
  		content = RSS::Maker.make(version) do |m|
  			m.channel.title = CONFIG["course_names"][@course_id]
  			m.channel.link = "https://woc.dei.uc.pt/weboncampus/class/getpresentation.do?idclass=#{@course_id}"
  			m.channel.description = "Scrapped #{CONFIG['course_names'][@course_id]} feed"
  			m.items.do_sort = true
  	
			puts "array size #{@mirror_items.size}"
		
				while @mirror_items.size > 0 do
  					item = @mirror_items.pop
  			
  				   # $ITEMS +=1
				   # puts "--------------------ITEM #{$ITEMS}-----------------"
  				   # puts "title: #{item.title}"
				   # puts "link: https://woc.dei.uc.pt/weboncampus/class/getpresentation.do?idclass=#{@course_id}"
				   # puts "enc_url: http://#{CONFIG['mirror_host']}/#{item.filename}"
				   # puts "end_length: #{item.file_length.to_s}"
				   # puts "date: #{item.published_at}"
				   # puts "-----------------------------------------------------"
			
  					#build the item
  					i = m.items.new_item
  					i.title = item.title
					#arrange description
					composed_description = "#{item.description}<br/>" || ""
					composed_description += item.sec_description || ""
  					i.description = composed_description
  					i.link = "https://woc.dei.uc.pt/weboncampus/class/getpresentation.do?idclass=#{@course_id}"
  					i.enclosure.url = "http://#{CONFIG['mirror_host']}/#{item.filename}"
  					i.enclosure.length = item.file_length.to_s
  					i.enclosure.type = "application/octet-stream"
  					unless item.published_at.nil?
  						i.date = Time.parse(item.published_at)
  					else
  						i.date = Time.now
  					end
  				end
	
			#puts "ITEMS -> #{$ITEMS}"
			#$ITEMS = 0
		end
		#puts content
		return content.to_s
	end
	
end

def translate_year(year_string)
	if CONFIG["years"][year_string].nil?
		return nil
	else
		return CONFIG["years"][year_string]
	end
end

def translate_course(course_string)
	if CONFIG["courses"][course_string].nil?
		return nil
	else
		return CONFIG["courses"][course_string]
	end
end

app = proc do |env|
	
	path_bits = env["REQUEST_PATH"].split("/")
	
	if path_bits.size == 3
		year_id = translate_year(path_bits[1])
		course_id = translate_course(path_bits[2])
	end
	
	if path_bits[1] == "mirror"
		[200, { 'Content-Type' => 'text/html' }, "Static file!"]
	elsif not year_id.nil? and not course_id.nil?
			builder = WocRssBuilder.new(course_id, year_id, env)
			[200, { 'Content-Type' => 'application/xhtml+xml' }, builder.build_rss]
	else
		[404, { 'Content-Type' => 'text/html'}, "Erro bodes e assim!"]
	end
end
Rack::Handler::Mongrel.run(app, :Port => 3000)
