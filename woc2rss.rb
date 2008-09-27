require 'rubygems'
require "net/http"
require "net/https"
require "yaml"
require "hpricot"
require "rss/maker"
require 'rack'
require 'sqlite3'

class WocFile
	
	attr_accessor :title, :description, :sec_description, :file_id, :file_type, :filename
	
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
				#puts 1
				#title
				tmp = WocFile.new
				tmp.title = td.inner_html.match(/<strong>(.*)<\/strong>/)[1]
			when /<strong>Tema: <\/strong>(.*)/
				#description
 				#puts td.inner_html.squeeze("\n")
				#TODO description
				#puts 2
   			when /.*<a href=.*/
				#download_link
				download_link = td.inner_html.match(/.*<a href="(.*)"(.|\n)*/)[1]
				link_bits = download_link.match(/\/weboncampus\/getFile.do\?tipo=(\d*)&id=(\d*)/)
				tmp.file_type = link_bits[1]
				tmp.file_id = link_bits[2]
   				@materials << tmp
				#puts 4
			else
				#sec_description
				#puts 3
				tmp.sec_description = td.inner_html.strip
 			end
 		end
		return @materials
	end
	
	def get_projects_list(class_id, year_id)
		#https://www.dei.uc.pt/weboncampus/class/getprojects.do?idclass=419&idyear=6
		response = self.auth_get("/weboncampus/class/getprojects.do?idclass=#{class_id}&idyear=#{year_id}")
		doc = Hpricot(response.body).search("td[@class='contentcell]")[1].search("table")[1].search("td").each do |td|
			case td.inner_html
			when /^\s*<strong>.*<\/strong>\s*$/
				next
			when /\s*<table(.|\n)*/
				next
			when /.*<a href=(.|\n)*/
				#download_link = td.inner_html.match(/.*<a href="(.*)"(.|\n)*/)[1]
				#link_bits = download_link.match(/\/weboncampus\/getFile.do\?tipo=(\d*)&id=(\d*)/)
				#tmp.file_type = link_bits[1]
				#tmp.file_id = link_bits[2]
				#@materials << tmp
				next
			when /^&nbsp;$/
				next
			when /\s*(<span)|(<b>)|(<font)(.|\n).*/
				next
			else
				puts td.inner_html
			end
		end
	end
	
	#returns filename and filecontent
	def get_file(file_id, file_type)
		response = self.auth_get("/weboncampus/getFile.do?tipo=#{file_type}&id=#{file_id}")
		filename = response["content-disposition"].match(/filename=(.*)/)[1]
		return filename, response.body
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
	
	def initialize(db_filename, woc_url, woc_username, woc_password)
		@download_retries = CONFIG["download_retires"]
		@mirror_path = CONFIG["mirror_path"]
		@db = SQLite3::Database.open(db_filename)
		@woc_worker = WocWorker.new(woc_url)
		@woc_worker.login!(woc_username, woc_password)
	end
	
	def mirror_file(file_id, file_type)
		
		#download the file
		new_filename, new_filedata = @woc_worker.get_file(file_id, file_type)
		new_file = File.new(@mirror_path + "/#{new_filename}", 'w')
		new_file.write(new_filedata)
		new_file.close
	rescue => e
		@download_retries -= 1
		retry unless @download_retires >= 0
	end
		
		#insert db entry
		db.execute("INSERT INTO mirror_files (download_link, file_id, file_type, filename) VALUES ('#{}','#{file_id}','#{file_type}','#{new_filename}')")
		
		return new_filename
	end
	
	def mirror_filename(file_id, file_type)
		filename = db.get_first_value("SELECT filename FROM mirror_files WHERE file_type = '#{file_type}' AND file_id = '#{file_id}'")
		if filename.nil?
			filename = self.mirror_file(file_id, file_type)
			return filename
		else
			return filename
		end
	end
	
end


#CONFIG = YAML.load(File.open("#{ENV['HOME']}/.deisync.yml"))
CONFIG = YAML.load(File.open("woc2rss.yml"))

COURSES = CONFIG["courses"]
YEARS = CONFIG["years"]

@worker = WocWorker.new(CONFIG['url'])
@worker.login!(CONFIG['username'], CONFIG['password'])
@worker.get_file(2,6180)
#b = @worker.get_generic_list("materialavaliation", "419", "5")[1]
#puts b.file_type
#puts b.file_id
#puts b.download_link

class WocRssBuilder
	
	def initialize(course_id, year_id)
		@course_id = course_id
		@year_id = year_id
		#woc queue
		@woc_items = Array.new
		@woc_mutex = Mutex.new
		#mirror queue
		@mirror_items = Array.new
		@mirror_mutex = Mutex.new
		#worker instances
		@mirror_workers = Array.new
		@woc_workers = Array.new
		@woc_worker = WocWorker.new(CONFIG['url'])
		@woc_worker.login!(CONFIG['username'], CONFIG['password']) #FIXME this shouln't be here
	end
	
	def build_rss
		
		#spawn one thread to download the material avaliation items
		@woc_workers << Thread.new(@woc_worker) do |woc_worker|
			items = @woc_worker.get_generic_list("materialavaliation", @course_id, @year_id)
			@woc_mutex.synchronize do
				@woc_items << items
			end
		end
		
		#spawn one thread to download the material items
		@woc_workers << Thread.new(@woc_worker) do |woc_worker|
			items = @woc_worker.get_generic_list("material", @course_id, @year_id)
			@woc_mutex.synchronize do
				@woc_items << items
			end
		end
		
		#spawn one thread to download the project items
		@woc_workers << Thread.new(@woc_worker) do |woc_worker|
			items = @woc_worker.get_projects_list(@course_id, @year_id)
			@woc_mutex.synchronize do
				@woc_items << items
			end
		end
		
		#spawn worker_num threads to mirror the woc items
		@worker_num.times do
			@mirror_workers << Thread.new(MirrorWorker.new) do |mirror_worker|
				#consume items from @woc_items
				#create rss item
				#produce items to @mirror_items
			end
		end
	end
	
	def create_rss
		version = "2.0"
		#destination = "test_make.xml"
		
		content = RSS::Maker.make(version) do |m|
			
			for item in @mirror_items do
				m.channel.title = "Cadeira X"
				m.channel.link = "http://www.dei.uc.pt"
				m.channel.description = "Feed do woc"
				m.items.do_sort = true

				i = m.items.new_item
				i.title = "Hey, i'm the first one"
				i.link = "http://www.google.com" 
				i.enclosure.url = "http://blog.makezine.com/crackerBoxAmp09.jpg"
				i.enclosure.length = "1000"
				i.enclosure.type = "application/octet-stream"
				i.date = Time.parse("2008/2/1 23:12")

				i = m.items.new_item
				i.title = "Hey i'm the second item"
				i.link = "http://www.sapo.pt"
				i.date = Time.now
			end
		end
		return content
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
	
	unless year_id.nil? or course_id.nil?
			
			[200, { 'Content-Type' => 'text/html' }, "valido!"]
	else
		[404, { 'Content-Type' => 'text/html'}, "Erro bodes e assim!"]
	end
end
#Rack::Handler::Mongrel.run(app, :Port => 3000)
