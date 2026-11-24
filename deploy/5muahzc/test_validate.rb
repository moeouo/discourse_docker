#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"

class DiscourseConfigValidatorTest < Minitest::Test
  DEPLOY_DIR = __dir__
  REPO_ROOT = File.expand_path("../..", DEPLOY_DIR)
  VALIDATOR = File.join(DEPLOY_DIR, "validate.rb")
  SOURCE_APP = File.join(DEPLOY_DIR, "app.yml")

  def load_source
    YAML.safe_load(File.read(SOURCE_APP), permitted_classes: [], aliases: false)
  end

  def production_app
    load_source.tap do |app|
      app["env"].merge!(
        "DISCOURSE_HOSTNAME" => "forum.example.org",
        "DISCOURSE_DEVELOPER_EMAILS" => "admin@example.org",
        "DISCOURSE_SMTP_ADDRESS" => "smtp.example.org",
        "DISCOURSE_SMTP_PORT" => 587,
        "DISCOURSE_SMTP_USER_NAME" => "discourse@example.org",
        "DISCOURSE_SMTP_PASSWORD" => "test-only-not-a-real-secret",
        "DISCOURSE_NOTIFICATION_EMAIL" => "noreply@example.org"
      )
    end
  end

  def with_temporary_app(app)
    Dir.mktmpdir(".validator-test-", DEPLOY_DIR) do |dir|
      path = File.join(dir, "app.yml")
      File.write(path, YAML.dump(app))
      yield path, dir
    end
  end

  def run_validator(path, allow_placeholders: false)
    command = ["ruby", VALIDATOR, "--app", path]
    command << "--allow-placeholders" if allow_placeholders
    Open3.capture3(*command)
  end

  def test_valid_production_config_passes
    with_temporary_app(production_app) do |path, _dir|
      _stdout, stderr, status = run_validator(path)
      assert status.success?, "expected valid production config to pass: #{stderr}"
    end
  end

  def test_placeholders_are_rejected
    with_temporary_app(load_source) do |path, _dir|
      _stdout, stderr, status = run_validator(path)
      refute status.success?, "unfinished deployment values must fail validation"
      assert_includes stderr, "deployment placeholders remain"
    end
  end

  def test_official_web_template_is_required
    app = production_app
    app["templates"].map! do |path|
      File.basename(path) == "web.template.yml" ? "deploy/5muahzc/legacy-web.yml" : path
    end

    with_temporary_app(app) do |path, _dir|
      _stdout, stderr, status = run_validator(path)
      refute status.success?, "replacing the official Web template must fail"
      assert_includes stderr, "missing official template: templates/web.template.yml"
    end
  end

  def test_custom_base_image_is_rejected
    app = production_app

    with_temporary_app(app) do |path, dir|
      overlay = File.join(dir, "pinned-base.yml")
      File.write(overlay, "base_image: discourse/base:test-pinned\n")
      relative = Pathname.new(overlay).relative_path_from(Pathname.new(REPO_ROOT)).to_s
      app["templates"] << relative
      File.write(path, YAML.dump(app))

      _stdout, stderr, status = run_validator(path)
      refute status.success?, "a custom base_image must fail validation"
      assert_includes stderr, "local overlay must not declare base_image"
    end
  end

  def test_database_connection_budget_is_enforced
    app = production_app
    app["env"]["UNICORN_WORKERS"] = 24

    with_temporary_app(app) do |path, _dir|
      _stdout, stderr, status = run_validator(path)
      refute status.success?, "24 Web Workers with 200 connections must fail the budget"
      assert_includes stderr, "database connection budget exceeded"
    end
  end

  def overlay_script(name)
    path = File.join(DEPLOY_DIR, "overlays", name)
    document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    document.fetch("run").first.fetch("exec").fetch("cmd").first
  end

  def test_postgres_overlay_applies_and_verifies_settings
    values = {
      "maintenance_work_mem" => "2GB",
      "effective_cache_size" => "64GB",
      "max_connections" => "200",
      "wal_buffers" => "16MB",
      "min_wal_size" => "2GB",
      "max_wal_size" => "8GB",
      "checkpoint_completion_target" => "0.9",
      "random_page_cost" => "1.1",
      "effective_io_concurrency" => "200",
      "max_worker_processes" => "16",
      "max_parallel_workers" => "16",
      "max_parallel_workers_per_gather" => "4",
      "max_parallel_maintenance_workers" => "4"
    }

    Dir.mktmpdir(".postgres-overlay-test-", DEPLOY_DIR) do |dir|
      postgres_root = File.join(dir, "postgres")
      Dir.mkdir(postgres_root)
      version_dir = File.join(postgres_root, "18")
      Dir.mkdir(version_dir)
      main_dir = File.join(version_dir, "main")
      Dir.mkdir(main_dir)
      config = File.join(main_dir, "postgresql.conf")
      File.write(config, values.keys.map { |key| "##{key} = old-value" }.join("\n") + "\n")

      script = overlay_script("postgres.tuning.template.yml").gsub("/etc/postgresql", postgres_root)
      env = values.transform_keys { |key| "db_#{key}" }
      env.delete("db_max_parallel_workers_per_gather")
      env["db_parallel_workers_per_gather"] = values["max_parallel_workers_per_gather"]
      stdout, stderr, status = Open3.capture3(env, "bash", stdin_data: script)
      assert status.success?, "PostgreSQL overlay failed: #{stdout}#{stderr}"

      result = File.read(config)
      values.each do |key, value|
        assert_includes result, "#{key} = #{value}\n"
      end
    end
  end

  def test_postgres_overlay_survives_pups_style_parameter_substitution
    script = overlay_script("postgres.tuning.template.yml")
    load_source.fetch("params").each do |key, value|
      script = script.gsub("$#{key}", value.to_s)
    end

    assert_includes script, 'set_pg_param max_parallel_workers_per_gather "4"'
  end

  def test_ambiguous_pups_parameter_prefixes_are_rejected
    app = production_app
    app["params"]["db_custom"] = "one"
    app["params"]["db_custom_value"] = "two"

    with_temporary_app(app) do |path, _dir|
      _stdout, stderr, status = run_validator(path)
      refute status.success?, "a parameter name that prefixes another must fail validation"
      assert_includes stderr, "ambiguous Pups parameter prefix"
    end
  end

  def test_china_mirror_overlay_uses_modern_bundler_config_syntax
    path = File.join(DEPLOY_DIR, "overlays", "china.mirrors.template.yml")
    document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    command = document.fetch("hooks").fetch("before_bundle_exec").first.fetch("exec").fetch("cmd").first

    assert_includes command, "bundle config set --global mirror.https://rubygems.org"
    refute_includes command, "bundle config set mirror.https://rubygems.org"
    refute_includes command, "bundle config mirror.https://rubygems.org"
  end

  def test_bundler_mirror_is_explicitly_set_for_the_discourse_project
    path = File.join(DEPLOY_DIR, "overlays", "china.mirrors.template.yml")
    document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    execution = document.fetch("hooks").fetch("before_bundle_exec").first.fetch("exec")
    command = execution.fetch("cmd").first

    assert_equal "$home", execution["cd"]
    assert_includes command, "bundle config set --local mirror.https://rubygems.org"
    assert_includes command, "bundle config get --local mirror.https://rubygems.org"
  end

  def test_web_overlay_applies_and_verifies_worker_count
    Dir.mktmpdir(".nginx-overlay-test-", DEPLOY_DIR) do |dir|
      config = File.join(dir, "nginx.conf")
      File.write(config, "user www-data;\nworker_processes auto;\n\nevents {\n  worker_connections 4000;\n}\n")
      script = overlay_script("web.tuning.template.yml").gsub("/etc/nginx/nginx.conf", config)
      stdout, stderr, status = Open3.capture3({ "nginx_workers" => "16" }, "bash", stdin_data: script)

      assert status.success?, "Nginx overlay failed: #{stdout}#{stderr}"
      assert_includes File.read(config), "worker_processes 16;\n"
    end
  end
end
