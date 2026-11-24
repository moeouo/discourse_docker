#!/usr/bin/env ruby
# frozen_string_literal: true

require "ipaddr"
require "optparse"
require "yaml"

DEPLOY_DIR = __dir__
REPO_ROOT = File.expand_path("../..", DEPLOY_DIR)
SOURCE_APP = File.join(DEPLOY_DIR, "app.yml")
ACTIVE_APP = File.join(REPO_ROOT, "containers", "app.yml")
LOCAL_PREFIX = "deploy/5muahzc/"

OFFICIAL_TEMPLATES = %w[
  templates/postgres.template.yml
  templates/redis.template.yml
  templates/web.template.yml
  templates/web.ratelimited.template.yml
  templates/web.ssl.template.yml
  templates/web.letsencrypt.ssl.template.yml
  templates/enable-ruby-yjit.yml
].freeze

OVERLAY_TEMPLATES = %w[
  deploy/5muahzc/overlays/postgres.tuning.template.yml
  deploy/5muahzc/overlays/china.mirrors.template.yml
  deploy/5muahzc/overlays/web.tuning.template.yml
].freeze

EXPECTED_TEMPLATE_ORDER = %w[
  templates/postgres.template.yml
  deploy/5muahzc/overlays/postgres.tuning.template.yml
  templates/redis.template.yml
  deploy/5muahzc/overlays/china.mirrors.template.yml
  templates/web.template.yml
  deploy/5muahzc/overlays/web.tuning.template.yml
  templates/web.ratelimited.template.yml
  templates/web.ssl.template.yml
  templates/web.letsencrypt.ssl.template.yml
  templates/enable-ruby-yjit.yml
].freeze

options = { source: false, allow_placeholders: false }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby validate.rb [--source] [--app PATH] [--allow-placeholders]"
  opts.on("--source", "Validate deploy/5muahzc/app.yml") { options[:source] = true }
  opts.on("--app PATH", "Validate an explicit app.yml path") { |path| options[:app] = path }
  opts.on("--allow-placeholders", "Warn instead of failing on deployment placeholders") do
    options[:allow_placeholders] = true
  end
end

begin
  parser.parse!(ARGV)
rescue OptionParser::ParseError => e
  abort(e.message)
end

abort("Unknown argument(s): #{ARGV.join(" ")}") unless ARGV.empty?
abort("--app and --source cannot be used together") if options[:app] && options[:source]

app_path = if options[:app]
             File.expand_path(options[:app], REPO_ROOT)
           elsif options[:source]
             SOURCE_APP
           else
             File.exist?(ACTIVE_APP) ? ACTIVE_APP : SOURCE_APP
           end

load_yaml = lambda do |path|
  YAML.safe_load(File.read(path), permitted_classes: [], aliases: false, filename: path)
end

begin
  app = load_yaml.call(app_path)
rescue StandardError => e
  abort("YAML ERROR in #{app_path}: #{e.message}")
end

abort("YAML ERROR: root value must be a mapping") unless app.is_a?(Hash)

errors = []
warnings = []
templates = app["templates"]
if !templates.is_a?(Array) || templates.empty?
  errors << "templates must be a non-empty array"
  templates = []
elsif templates.any? { |path| !path.is_a?(String) }
  errors << "every template path must be a string"
  templates = templates.select { |path| path.is_a?(String) }
end

OFFICIAL_TEMPLATES.each do |path|
  errors << "missing official template: #{path}" unless templates.include?(path)
end

OVERLAY_TEMPLATES.each do |path|
  errors << "missing local overlay: #{path}" unless templates.include?(path)
end

if templates.take(EXPECTED_TEMPLATE_ORDER.length) != EXPECTED_TEMPLATE_ORDER
  errors << "template order must preserve official templates and their designated overlays"
end

local_templates = templates.select { |path| path.start_with?(LOCAL_PREFIX) }
(local_templates - OVERLAY_TEMPLATES).each do |path|
  errors << "unapproved local template: #{path}"
end

if app.key?("base_image")
  errors << "app.yml must not declare base_image; inherit the official dated tag"
end

merged_params = {}
merged_env = {}
documents = {}
template_text = []

templates.each do |relative_path|
  path = File.join(REPO_ROOT, relative_path)
  unless File.file?(path)
    errors << "missing template file: #{relative_path}"
    next
  end

  begin
    document = load_yaml.call(path)
    unless document.is_a?(Hash)
      errors << "template root must be a mapping: #{relative_path}"
      next
    end

    documents[relative_path] = document
    template_text << File.read(path)
    merged_params.merge!(document["params"] || {})
    merged_env.merge!(document["env"] || {})

    if relative_path.start_with?(LOCAL_PREFIX) && document.key?("base_image")
      errors << "local overlay must not declare base_image: #{relative_path}"
    end
  rescue StandardError => e
    errors << "YAML ERROR in #{relative_path}: #{e.message}"
  end
end

merged_params.merge!(app["params"] || {})
merged_env.merge!(app["env"] || {})

official_web = documents["templates/web.template.yml"]
if official_web
  official_base = official_web["base_image"].to_s
  if official_base.empty?
    errors << "official Web template does not provide base_image"
  elsif official_base == "discourse/base:latest"
    errors << "floating discourse/base:latest is not allowed"
  end
end

expected_params = {
  "db_synchronous_commit" => "on",
  "db_shared_buffers" => "16GB",
  "db_work_mem" => "16MB",
  "db_maintenance_work_mem" => "2GB",
  "db_effective_cache_size" => "64GB",
  "db_max_connections" => "200",
  "db_wal_buffers" => "16MB",
  "db_min_wal_size" => "2GB",
  "db_max_wal_size" => "8GB",
  "db_checkpoint_completion_target" => "0.9",
  "db_random_page_cost" => "1.1",
  "db_effective_io_concurrency" => "200",
  "db_max_worker_processes" => "16",
  "db_max_parallel_workers" => "16",
  "db_parallel_workers_per_gather" => "4",
  "db_max_parallel_maintenance_workers" => "4",
  "redis_io_threads" => "4",
  "nginx_workers" => 16,
  "nginx_worker_connections" => 8192
}

expected_env = {
  "UNICORN_WORKERS" => 16,
  "UNICORN_SIDEKIQS" => 4,
  "DISCOURSE_DB_POOL" => 8,
  "DISCOURSE_SIDEKIQ_WORKERS" => 5,
  "RUBY_YJIT_ENABLE" => 1,
  "DISCOURSE_DEFAULT_LOCALE" => "zh_CN"
}

expected_params.each do |key, expected|
  actual = merged_params[key]
  errors << "#{key}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

expected_env.each do |key, expected|
  actual = merged_env[key]
  errors << "#{key}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

template_text.join("\n").scan(/\$(db_[a-z_]+|nginx_[a-z_]+)/).flatten.uniq.sort.each do |key|
  errors << "undefined template parameter: #{key}" unless merged_params.key?(key)
end

# Pups replaces "$name" textually. A key followed by an underscore-prefixed
# suffix can therefore corrupt the longer key before that key is substituted.
pups_keys = merged_params.keys.grep(/\A(?:db_|nginx_)/).sort
pups_keys.combination(2) do |shorter, longer|
  if longer.start_with?("#{shorter}_")
    errors << "ambiguous Pups parameter prefix: #{shorter} is a prefix of #{longer}"
  end
end

workers = merged_env["UNICORN_WORKERS"].to_i
sidekiqs = merged_env["UNICORN_SIDEKIQS"].to_i
db_pool = merged_env["DISCOURSE_DB_POOL"].to_i
sidekiq_threads = merged_env["DISCOURSE_SIDEKIQ_WORKERS"].to_i
max_connections = merged_params["db_max_connections"].to_i
connection_budget = workers * db_pool + sidekiqs * sidekiq_threads + 30
if connection_budget > max_connections
  errors << "database connection budget exceeded: #{connection_budget} required, #{max_connections} configured"
end

required_env = %w[
  DISCOURSE_HOSTNAME
  DISCOURSE_DEVELOPER_EMAILS
  DISCOURSE_SMTP_ADDRESS
  DISCOURSE_SMTP_PORT
  DISCOURSE_SMTP_USER_NAME
  DISCOURSE_SMTP_PASSWORD
  DISCOURSE_NOTIFICATION_EMAIL
]

required_env.each do |key|
  value = merged_env[key]
  errors << "missing required env: #{key}" if value.nil? || value.to_s.strip.empty?
end

placeholder_values = {
  "DISCOURSE_HOSTNAME" => ["discourse.example.com"],
  "DISCOURSE_DEVELOPER_EMAILS" => ["CHANGE_ME@example.com"],
  "DISCOURSE_SMTP_ADDRESS" => ["smtp.example.com"],
  "DISCOURSE_SMTP_USER_NAME" => ["CHANGE_ME@example.com"],
  "DISCOURSE_SMTP_PASSWORD" => ["CHANGE_ME"],
  "DISCOURSE_NOTIFICATION_EMAIL" => ["noreply@example.com"]
}

placeholders = required_env.select do |key|
  value = merged_env[key].to_s
  value.include?("CHANGE_ME") || Array(placeholder_values[key]).include?(value)
end

if placeholders.any?
  message = "deployment placeholders remain: #{placeholders.join(", ")}"
  options[:allow_placeholders] ? warnings << message : errors << message
end

hostname = merged_env["DISCOURSE_HOSTNAME"].to_s
unless placeholders.include?("DISCOURSE_HOSTNAME") || hostname.empty?
  begin
    IPAddr.new(hostname)
    errors << "DISCOURSE_HOSTNAME must be a DNS name, not an IP address"
  rescue IPAddr::InvalidAddressError
    hostname_pattern = /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i
    errors << "DISCOURSE_HOSTNAME is not a valid fully qualified DNS name" unless hostname.match?(hostname_pattern)
  end
end

{
  "DISCOURSE_DEVELOPER_EMAILS" => merged_env["DISCOURSE_DEVELOPER_EMAILS"].to_s.split(","),
  "DISCOURSE_SMTP_USER_NAME" => [merged_env["DISCOURSE_SMTP_USER_NAME"].to_s],
  "DISCOURSE_NOTIFICATION_EMAIL" => [merged_env["DISCOURSE_NOTIFICATION_EMAIL"].to_s]
}.each do |key, addresses|
  next if placeholders.include?(key)
  unless addresses.all? { |address| address.strip.match?(/\A[^@\s]+@[^@\s]+\z/) }
    errors << "#{key} contains an invalid email address"
  end
end

smtp_port = merged_env["DISCOURSE_SMTP_PORT"].to_i
errors << "DISCOURSE_SMTP_PORT must be between 1 and 65535" unless (1..65_535).cover?(smtp_port)
if smtp_port == 465 && merged_env["DISCOURSE_SMTP_FORCE_TLS"] != true
  errors << "DISCOURSE_SMTP_FORCE_TLS must be true when SMTP port 465 is used"
elsif smtp_port == 587 && merged_env["DISCOURSE_SMTP_FORCE_TLS"] == true
  warnings << "port 587 normally uses STARTTLS; verify that implicit TLS is really required"
end

if merged_env["DISCOURSE_SKIP_EMAIL_SETUP"].to_s == "1"
  errors << "DISCOURSE_SKIP_EMAIL_SETUP must not bypass production mail validation"
end

github_mirror = merged_env["GITHUB_MIRROR"].to_s
if !github_mirror.empty? && !github_mirror.match?(%r{\Ahttps://[^\s"']+\z})
  errors << "GITHUB_MIRROR must be empty or a valid HTTPS replacement prefix"
end

docker_args = app["docker_args"].to_s
{
  "--cpus=72" => "CPU limit",
  "--memory=112g" => "memory limit",
  "--memory-swap=112g" => "swap limit",
  "--pids-limit=8192" => "PID limit",
  "--log-driver=json-file" => "Docker log driver",
  "--log-opt=max-size=100m" => "Docker log size",
  "--log-opt=max-file=5" => "Docker log rotation"
}.each do |flag, description|
  errors << "missing #{description}: #{flag}" unless docker_args.include?(flag)
end

exposed = Array(app["expose"]).map(&:to_s)
%w[80:80 443:443].each do |port|
  errors << "missing exposed port: #{port}" unless exposed.include?(port)
end

containers_root = File.join(REPO_ROOT, "containers") + File::SEPARATOR
if app_path.start_with?(containers_root) && File.exist?(app_path) && (File.stat(app_path).mode & 0o077) != 0
  warnings << "#{app_path} is accessible by group/other users; run chmod 600 #{app_path}"
end

puts "Validating: #{app_path}"
puts "Templates: #{templates.length} (#{OFFICIAL_TEMPLATES.length} official, #{local_templates.length} local)"
warnings.each { |message| puts "WARNING: #{message}" }

if errors.empty?
  puts "OK: official-template composition, overlays, resources and deployment values are valid."
else
  errors.each { |message| STDERR.puts "ERROR: #{message}" }
  abort("FAILED: #{errors.length} error(s)")
end
