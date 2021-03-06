# Copyright (c) Bart Kamphorst <rubycron@kamphorst.com>, 2011 - 2014.
# Licensed under the modified BSD License. All rights reserved.

module RubyCron

  class RubyCronJob
  
  require 'net/smtp'
  require 'yaml'
  require 'open-uri'
  require 'rubygems'
  require 'mail'
  require 'erb'
  
  attr_accessor :name, :author, :mailto, :mailfrom, :mailsubject, :mailon, :exiton, :template, :smtpsettings, :debug, :logfile, :verbose
  attr_reader   :messages, :warnings, :errors, :report
  
  DEFAULT_SERVER = 'localhost'
  DEFAULT_PORT   = 25
  
    def initialize(args = nil)
      @messages, @warnings, @errors = [], [], []
      
      case args
        when NilClass then yield self if block_given?
        when Proc     then instance_eval(&args)
        when Hash     then 
          
          args = load_config(:file, args[:configfile]).merge(args) if args[:configfile]
          args = load_config(:url, args[:configurl]).merge(args)   if args[:configurl] 
          
          args.each do |key, value|
            instance_variable_set("@#{key}", value) if value
          end
        else terminate "Expected a hash or a block to initialize, but instead received a #{args.class} object."
      end
            
      check_sanity
      
      rescue => e
        terminate(e.message)
    end
    
    def load_config(source_type, source)
      if source_type == :file
        io = File.open(source) if File.file?(source)
      elsif source_type == :url
        io = open(source)
      end
      yml = YAML::load(io)
      if yml.is_a?(Hash)
        return yml
      else
        terminate "Could not load the YAML configuration."
      end
    end
    
    def check_sanity
      raise "This job has no name."   unless @name 
      raise "This job has no author." unless @author
      raise "No To: header was set. " unless @mailto
      
      check_smtp_settings
      set_defaults
      enable_debug_mode if @debug
      enable_file_logging if @logfile  
    end
    
    def check_smtp_settings     
      if @smtpsettings
        raise "SMTP settings have to be passed in as a hash." unless @smtpsettings.instance_of?(Hash)
        raise "SMTP settings should include at least an address (:address)." unless @smtpsettings.keys.include?(:address)
        raise "SMTP settings should include at least a port number (:port)." unless @smtpsettings.keys.include?(:port)
      elsif @smtpsettings.nil?
        raise "Cannot connect to local smtp server." unless smtp_connection?
      end
    end
    
    def set_defaults
      @mailfrom       ||= 'root@localhost' 
      @verbose        ||= false 
      @template       ||= File.join(File.dirname(__FILE__), '/report.erb')
      @mailon = :all unless self.mailon && [:none, :warning, :error, :all].include?(self.mailon)
      @exiton = :all unless self.exiton && [:none, :warning, :error, :all].include?(self.exiton)
    end
    
    def enable_debug_mode
      @mailon = :none
      @verbose = true
    end
    
    def enable_file_logging
      $stdout.reopen(@logfile, "a")
      $stdout.sync = true
      $stderr.reopen($stdout)
      rescue => e
        $stdout, $stderr = STDOUT, STDERR
        raise e
    end
        
    def terminate(message)
      $stderr.puts "## Cannot complete job. Reason: #{message}" unless ENV['RSPEC']
      exit 1
    end
    
    # Execute a given block of code (the cronjob), rescue encountered errors, 
    # and send a report about it if necessary.
    def execute(&block)
      puts "[INFO ] Running in debug mode. Will not send mail." if self.debug
      @starttime = Time.now
      puts "\nStarting run of #{self.name} at #{@starttime}.\n----"  if self.verbose || self.logfile
      instance_eval(&block)
    rescue ExitOnWarning, ExitOnError => e
      terminate(e.message)
    rescue Exception => e
      trace = "#{e.message}\n" + e.backtrace.join("\n\t")
      @errors << trace
      $stderr.puts "[ERROR] #{trace}" if self.verbose || self.logfile
      terminate(trace) if exiton == (:error || :all)
    ensure
      @endtime = Time.now
      produce_summary if (self.verbose || self.logfile)
      unless self.mailon == :none || (@warnings.empty? && @errors.empty? && self.mailon != :all)
        send_report
      end 
    end
   
    def produce_summary
      puts "Run ended at #{@endtime}.\n----"  
      puts "Number of messages: #{@messages.size}"
      puts "Number of warnings: #{@warnings.size}" 
      puts "Number of errors  : #{@errors.size}"
    end
   
    def message(message)
      $stderr.puts "[INFO ] #{message}" if self.verbose || self.logfile
      @messages << message
    end
    alias_method :info, :message
    
    def warning(message)
     $stderr.puts "[WARN ] #{message}" if self.verbose || self.logfile
     @warnings << message
     raise ExitOnWarning.new("Configured to exit on warning.") if exiton == (:warning || :all)
    end

    def error(message)
      $stderr.puts "[ERROR] #{message}" if self.verbose || self.logfile
      @errors << message
      raise ExitOnError.new("Configured to exit on error.") if exiton == (:error || :all) 
    end
    
    private 
    def smtp_connection?
      return true if Net::SMTP.start(DEFAULT_SERVER, DEFAULT_PORT)
      rescue 
        return false
    end
    
    # Report on the status of the cronjob through the use of
    # an erb template file, and mikel's excellent mail gem. 
    private
    def send_report
      @report       = ERB.new(File.read(@template)).result(binding)      
      @mailsubject  = "Cron report for #{name}: #{@warnings.size} warnings & #{@errors.size} errors" unless @mailsubject
      
      mailfrom      = @mailfrom
      mailto        = @mailto
      mailsubject   = @mailsubject
      mailbody      = @report
    
      if @smtpsettings
        smtpsettings = @smtpsettings 
        Mail.defaults do
          delivery_method :smtp, smtpsettings
        end
      end
      
      mail = Mail.new do
        from    mailfrom
        to      mailto
        subject mailsubject
        body    mailbody
      end

      mail.deliver!
      rescue => e
        terminate(e.message)      
    end  
  end
end