require 'ostruct'
require 'time'
require 'net/irc'
require 'octokit'

class Agig::Session < Net::IRC::Server::Session
  def server_name
    "github"
  end

  def server_version
    Agig::VERSION
  end

  def channels
    ['#notification']
  end

  def initialize(*args)
    super
    @notification_last_retrieved = Time.now.utc - 3600
  end

  def client
    @client ||= if @opts.oauth_token
                  Octokit::Client.new(oauth_token: @pass)
                else
                  Octokit::Client.new(login: @nick, password: @pass)
                end
  end

  def on_disconnected
    @retrieve_thread.kill rescue nil
  end

  def on_user(m)
    super

    @real, *@opts = @real.split(/\s+/)
    @opts = OpenStruct.new @opts.inject({}) {|r, i|
      key, value = i.split("=", 2)
      r.update key => case value
                      when nil                      then true
                      when /\A\d+\z/                then value.to_i
                      when /\A(?:\d+\.\d*|\.\d+)\z/ then value.to_f
                      else                               value
                      end
    }
    channels.each{|channel| post @nick, JOIN, channel }

    @retrieve_thread = Thread.start do
      loop do
        begin
          @log.info 'retrieveing feed...'

          notifications = client.notifications(all: true)
          notifications = notifications.sort {|a, b| a[:updated_at] <=> b[:updated_at]}
          notifications.each do |notification|
            updated_at = notification[:updated_at]
            next if updated_at <= @notification_last_retrieved

            subject        = notification[:subject]
            repository     = notification[:repository]
            latest_comment = subject.rels[:latest_comment].get.data
            issue_id       = latest_comment[:number] || begin
              issue = (issue = latest_comment.rels[:issue]) && issue.get.data
              issue && issue[:number]
            end
            if issue_id
              reachable_url =  "https://github.com/#{repository[:full_name]}/issues/#{issue_id}"
              reachable_url << "#issuecomment-#{latest_comment[:id]}"
            end

            post notification[:repository][:owner][:login], PRIVMSG, "#notification", "\0035#{subject[:title]}\017 \00314#{reachable_url}\017"
            latest_comment[:body].each_line do |line|
              next if line.chomp =~ /^[ 　\t\r\n]*$/
              post notification[:repository][:owner][:login], PRIVMSG, "#notification", line
            end
            post '---', PRIVMSG, "#notification", '-' * 50
            @notification_last_retrieved = updated_at
          end

          @log.info 'sleep'
          sleep 30
        rescue Exception => e
          @log.error e.inspect
          e.backtrace.each do |l|
            @log.error "\t#{l}"
          end
          sleep 10
        end
      end
    end
  end
end
