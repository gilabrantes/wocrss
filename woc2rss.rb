require 'rubygems'
require "net/http"
require "net/https"
require "yaml"
require "hpricot"
require "rss/maker"

class WocFile
	
	attr_accessor :download_link, :title, :description, :sec_description
	
end

class WocWorker
	
	attr_accessor :conn
	
	def initialize(url)
		@cookies = Hash.new
		@conn = Net::HTTP.new(url, 443)
		@conn.use_ssl = true
		@conn.verify_mode = OpenSSL::SSL::VERIFY_NONE
	end
	
	def test_method
		#self
	end
	
	def login(username, password)
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
		#TODO
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
				tmp.download_link = td.inner_html.match(/.*<a href="(.*)"(.|\n)*/)[1]
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
		#TODO
		#https://www.dei.uc.pt/weboncampus/class/getprojects.do?idclass=419&idyear=6
		response = self.auth_get("/weboncampus/class/getprojects.do?idclass=#{class_id}&idyear=#{year_id}")
		doc = Hpricot(response.body).search("td[@class='contentcell]")[1].search("table")[1].search("td").each do |td|
			case td.inner_html
			when /^\s*<strong>.*<\/strong>\s*$/
				next
			when /\s*<table(.|\n)*/
				next
			when /.*<a href=(.|\n)*/
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
	
	def get_file
		#TODO
		#https://www.dei.uc.pt/weboncampus/getFile.do?tipo=2&id=6836
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

#CONFIG = YAML.load(File.open("#{ENV['HOME']}/.deisync.yml"))
CONFIG = YAML.load(File.open("woc2rss.yml"))

IDS = [ 419, 422, 439, 511, 515 ]


@worker = WocWorker.new(CONFIG['url'])
@worker.login("abrantes", "deftoned")
@worker.get_generic_list("materialavaliation", "419", "5")[1]


version = "2.0"
destination = "test_make.xml"
content = RSS::Maker.make(version) do |m|
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

File.open(destination, "w") do |f|
	f.write(content)
end
