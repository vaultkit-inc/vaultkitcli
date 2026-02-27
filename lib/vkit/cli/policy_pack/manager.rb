# frozen_string_literal: true

require "yaml"
require "fileutils"
require "time"
require "digest"

module Vkit
  module CLI
    module PolicyPack
      class Manager
        # Packs shipped with CLI (in the gem)
        PACKS_DIR = File.expand_path("../../policy/packs", __dir__)

        # Project-local state
        STATE_DIR_NAME = ".vkit"
        TRACKING_FILE_NAME = "packs.yaml"

        DEFAULT_POLICIES_DIR = File.join("config", "policies")

        class Error < StandardError; end
        class PackNotFound < Error; end
        class PackAlreadyInstalled < Error; end
        class PackNotInstalled < Error; end
        class DependencyMissing < Error; end
        class UnsafeOverwrite < Error; end
        class InvalidPack < Error; end

        def initialize(project_root: Dir.pwd, policies_dir: DEFAULT_POLICIES_DIR)
          @project_root = File.expand_path(project_root)
          @policies_dir = File.expand_path(policies_dir, @project_root)
        end

        def available_packs
          return [] unless Dir.exist?(PACKS_DIR)
        
          Dir.children(PACKS_DIR)
             .select { |name| File.directory?(File.join(PACKS_DIR, name)) }
             .sort
        end        

        def installed_packs
          state.dig("installed_packs") || {}
        end

        def installed?(pack_name)
          installed_packs.key?(pack_name)
        end

        def pack_metadata(pack_name)
          meta, _policies = read_pack!(pack_name)
          meta
        end

        # Install pack policies into project's policies_dir.
        #
        # Options:
        # - force: overwrite pack-installed files if they exist (refuses to overwrite non-pack files)
        # - dry_run: compute actions but do not write
        def install!(pack_name, force: false, dry_run: false)
          meta, policies = read_pack!(pack_name)

          if installed?(pack_name)
            raise PackAlreadyInstalled, "Pack '#{pack_name}' is already installed"
          end

          ensure_dependencies!(meta)

          FileUtils.mkdir_p(@policies_dir) unless dry_run

          validate_pack_policies!(pack_name, meta, policies)

          install_record = {
            "name" => pack_name,
            "version" => meta["version"],
            "layer" => meta["layer"],
            "installed_at" => Time.now.utc.iso8601,
            "pack_checksum" => pack_checksum(pack_name),
            "files" => []
          }

          policies.each_with_index do |policy, idx|
            policy_id = policy.fetch("id")
            ext = "yaml"

            filename = format("%<pack>s__%<idx>02d__%<id>s.%<ext>s",
                              pack: pack_name,
                              idx: (idx + 1),
                              id: safe_slug(policy_id),
                              ext: ext)

            dest = File.join(@policies_dir, filename)

            # Overwrite rules:
            # - if dest exists and is NOT tracked by this pack -> refuse
            # - if dest exists and force=false -> refuse
            # - if dest exists and force=true -> allow overwrite
            if File.exist?(dest)
              raise UnsafeOverwrite, "Refusing to overwrite existing file: #{dest}" unless force
              # force is allowed, but this file isn't yet tracked because pack isn't installed.
              # Still, we only allow overwriting if the file looks like our namespace.
              unless File.basename(dest).start_with?("#{pack_name}__")
                raise UnsafeOverwrite, "Refusing to overwrite non-pack file (missing namespace): #{dest}"
              end
            end

            content = render_policy_file(pack_name, meta, policy)

            unless dry_run
              File.write(dest, content)
            end

            install_record["files"] << {
              "path" => relative_to_root(dest),
              "policy_id" => policy_id
            }
          end

          write_state_add!(pack_name, install_record) unless dry_run

          install_record["files"].length
        end

        # Remove pack-installed policy files.
        #
        # Options:
        # - force: remove files even if missing (still won’t delete non-tracked files)
        def remove!(pack_name, force: false)
          unless installed?(pack_name)
            raise PackNotInstalled, "Pack '#{pack_name}' is not installed"
          end

          pack_entry = installed_packs[pack_name]
          files = Array(pack_entry["files"])

          removed = 0

          files.each do |f|
            abs = File.expand_path(f.fetch("path"), @project_root)

            if File.exist?(abs)
              FileUtils.rm_f(abs)
              removed += 1
            else
              raise Error, "Expected pack file missing: #{abs} (use --force to ignore)" unless force
            end
          end

          write_state_remove!(pack_name)

          removed
        end

        def list_status
          avail = available_packs
          installed = installed_packs

          avail.map do |name|
            shipped_meta = safe_pack_metadata(name)
            entry = installed[name]

            shipped_version = shipped_meta["version"]
            installed_version = entry && entry["version"]

            {
              "name" => name,
              "layer" => shipped_meta["layer"],
              "shipped_version" => shipped_version,
              "installed" => !entry.nil?,
              "installed_version" => installed_version,
              "drift" => entry && shipped_version && installed_version && shipped_version != installed_version
            }
          end
        end

        def upgrade!(pack_name, force: false, dry_run: false)
          unless installed?(pack_name)
            raise PackNotInstalled, "Pack '#{pack_name}' is not installed"
          end
        
          installed_entry = installed_packs[pack_name]
          installed_version = installed_entry["version"]
        
          shipped_meta = pack_metadata(pack_name)
          shipped_version = shipped_meta["version"]
        
          if installed_version == shipped_version
            return :up_to_date
          end
        
          remove!(pack_name, force: force) unless dry_run
        
          count = install!(pack_name, force: force, dry_run: dry_run)
        
          {
            old_version: installed_version,
            new_version: shipped_version,
            policies: count
          }
        end

        def upgrade_all!(force: false, dry_run: false)
          # installed packs ordered by layer (low -> high)
          packs = installed_packs.keys.sort_by { |name| safe_pack_metadata(name)["layer"].to_i }
        
          packs.each_with_object([]) do |pack, results|
            results << [pack, upgrade!(pack, force: force, dry_run: dry_run)]
          end
        end

        def install_with_deps!(pack_name, force: false, dry_run: false, visited: {})
          return 0 if installed?(pack_name)

          raise InvalidPack, "Circular dependency detected at '#{pack_name}'" if visited[pack_name]
          visited[pack_name] = true

          meta = pack_metadata(pack_name)
          deps = Array(meta["dependencies"])

          # Install dependencies first
          deps.each do |dep|
            install_with_deps!(dep, force: force, dry_run: dry_run, visited: visited)
          end

          # Enforce layering monotonicity
          deps.each do |dep|
            dep_layer = pack_metadata(dep)["layer"].to_i
            my_layer  = meta["layer"].to_i
            if dep_layer > my_layer
              raise InvalidPack, "Invalid layering: '#{pack_name}' layer #{my_layer} depends on '#{dep}' layer #{dep_layer}"
            end
          end

          install!(pack_name, force: force, dry_run: dry_run)
        ensure
          visited.delete(pack_name)
        end

        private

        # Pack reading & validation
        def read_pack!(pack_name)
          root = pack_root(pack_name)
          raise PackNotFound, "Pack '#{pack_name}' not found" unless Dir.exist?(root)
        
          metadata_path = File.join(root, "metadata.yaml")
          raise InvalidPack, "Missing metadata.yaml in pack '#{pack_name}'" unless File.exist?(metadata_path)
        
          meta_doc = YAML.safe_load(File.read(metadata_path), aliases: true)
          meta = meta_doc["__pack_meta"]
          required_keys = %w[name version layer]
          missing = required_keys.reject { |k| meta[k].to_s.strip != "" }

          unless missing.empty?
            raise InvalidPack, "Pack '#{pack_name}' missing required metadata keys: #{missing.join(", ")}"
          end

          unless Array(meta["dependencies"]).all? { |d| d.is_a?(String) }
            raise InvalidPack, "dependencies must be an array of strings"
          end

          raise InvalidPack, "Invalid __pack_meta in '#{pack_name}'" unless meta.is_a?(Hash)
        
          policies_dir = File.join(root, "policies")
          raise InvalidPack, "Missing policies/ directory in pack '#{pack_name}'" unless Dir.exist?(policies_dir)
        
          policy_files = Dir.glob(File.join(policies_dir, "*.yaml")).sort
          raise InvalidPack, "No policy files found in '#{pack_name}'" if policy_files.empty?
        
          policies = policy_files.map do |file|
            data = YAML.safe_load(File.read(file), aliases: true)
          
            unless data.is_a?(Hash)
              raise InvalidPack, "Policy file #{file} must be a Hash"
            end
          
            Vkit::Policy::PolicyValidator.validate!(data, file: File.basename(file))
          
            data
          end          
        
          policies.each do |p|
            raise InvalidPack, "Policy missing id in '#{pack_name}'" unless p.is_a?(Hash) && p["id"]
          end
        
          [meta, policies]
        end        

        def safe_pack_metadata(pack_name)
          pack_metadata(pack_name)
        rescue
          {}
        end

        def validate_pack_policies!(pack_name, meta, policies)
          band = meta["priority_band"] || {}
          min = band["min"]
          max = band["max"]

          return if min.nil? && max.nil?

          policies.each do |p|
            pr = p["priority"]
            next if pr.nil?
            if min && pr < min
              raise InvalidPack, "Pack '#{pack_name}' policy '#{p["id"]}' priority #{pr} below band min #{min}"
            end
            if max && pr > max
              raise InvalidPack, "Pack '#{pack_name}' policy '#{p["id"]}' priority #{pr} above band max #{max}"
            end
          end
        end

        def ensure_dependencies!(meta)
          deps = Array(meta["dependencies"])
          return if deps.empty?

          missing = deps.reject { |d| installed?(d) }
          return if missing.empty?

          raise DependencyMissing, "Pack requires dependencies not installed: #{missing.join(", ")}"
        end

        def pack_root(pack_name)
          File.join(PACKS_DIR, pack_name)
        end        

        def pack_checksum(pack_name)
          root = pack_root(pack_name)
        
          files = [
            File.join(root, "metadata.yaml"),
            *Dir.glob(File.join(root, "policies", "*.yaml")).sort
          ]
        
          digest = Digest::SHA256.new
          files.each do |file|
            digest.update(File.read(file))
          end
        
          digest.hexdigest
        end        

        # State file
        def state_dir
          File.join(@project_root, STATE_DIR_NAME)
        end

        def state_path
          File.join(state_dir, TRACKING_FILE_NAME)
        end

        def state
          return default_state unless File.exist?(state_path)
          YAML.safe_load(File.read(state_path), permitted_classes: [], permitted_symbols: [], aliases: true) || default_state
        rescue
          default_state
        end

        def default_state
          { "format_version" => "v1", "installed_packs" => {} }
        end

        def write_state_add!(pack_name, entry)
          s = state
          s["installed_packs"] ||= {}
          s["installed_packs"][pack_name] = entry

          FileUtils.mkdir_p(state_dir)
          File.write(state_path, s.to_yaml)
        end

        def write_state_remove!(pack_name)
          s = state
          s["installed_packs"] ||= {}
          s["installed_packs"].delete(pack_name)

          FileUtils.mkdir_p(state_dir)
          File.write(state_path, s.to_yaml)
        end

        # Rendering
        def render_policy_file(pack_name, meta, policy)
          header = <<~HEADER
            # VaultKit Policy Pack: #{pack_name}
            # Pack Version: #{meta["version"]}
            # Layer: #{meta["layer"]}
            # Installed At: #{Time.now.utc.iso8601}
            #
            # Generated by VaultKit CLI. You may edit this file.
            # To revert to upstream defaults: remove & re-add the pack.
            #
          HEADER

          body = policy.to_yaml
          body = body.sub(/\A---\s*\n/, "") # remove leading doc marker

          header + body
        end

        def safe_slug(value)
          value.to_s
               .strip
               .downcase
               .gsub(/[^a-z0-9]+/, "_")
               .gsub(/\A_+|_+\z/, "")
               .slice(0, 80)
        end

        def relative_to_root(abs_path)
          abs_path.sub(@project_root + File::SEPARATOR, "")
        end
      end
    end
  end
end
