require 'rubygems'
require 'sinatra'
require 'sequel'

Sinatra::Application.set :run => false
Sinatra::Application.set :environment => ENV['RACK_ENV']

require 'webglue.rb'
run Sinatra::Application
