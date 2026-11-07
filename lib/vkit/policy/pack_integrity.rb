# frozen_string_literal: true

require "yaml"
require_relative "validation_error"

module Vkit
  module Policy
    # Checks that every pack recorded in .vkit/packs.yaml still contributes
    # all of its policies, so a bundle can't quietly lose one (vaultkitcli#47).
    module PackIntegrity
      PACKS_DIR = File.expand_path("packs", __dir__)
      TRACKING_PATH = File.join(".vkit", "packs.yaml")
      VERSION_HEADER = /^# Pack Version: (.+)$/

      module_function

      # Installed packs as recorded, { name => entry }. A missing file means no
      # packs; an unreadable one is an error, since it would hide every pack.
      def installed_packs(project_root)
        path = File.join(project_root, TRACKING_PATH)
        return {} unless File.exist?(path)

        data = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true) || {}
        raise ValidationError, "#{TRACKING_PATH} is not a mapping" unless data.is_a?(Hash)

        packs = data["installed_packs"] || {}
        raise ValidationError, "#{TRACKING_PATH}: installed_packs is not a mapping" unless packs.is_a?(Hash)

        packs
      rescue Psych::Exception => e
        raise ValidationError, "Can't read #{TRACKING_PATH}: #{e.message}"
      end

      # Raises unless each installed pack's recorded files are all present in
      # policies_dir, at the recorded version, with the recorded policy ids.
      # `policies` are the loaded policy files, each with "__path".
      # Returns [{ "name", "version", "policy_ids" }] for the bundle.
      def check!(project_root:, policies_dir:, policies:)
        by_path = policies.to_h { |p| [real(p["__path"]), p] }
        problems = []

        packs = installed_packs(project_root).map do |name, entry|
          entry ||= {}
          version = entry["version"].to_s
          files = Array(entry["files"])
          pack_problems = []

          pack_problems << "no files recorded in #{TRACKING_PATH}" if files.empty?

          shipped = shipped_policy_ids(name, version)
          if shipped && files.length < shipped.length
            recorded = files.map { |f| f["policy_id"] }
            pack_problems << "#{TRACKING_PATH} records #{files.length} of the pack's #{shipped.length} policies " \
                             "(not recorded: #{(shipped - recorded).join(", ")})"
          end

          files.each do |f|
            rel = f["path"].to_s
            abs = File.expand_path(rel, project_root)
            expected_id = f["policy_id"].to_s

            unless File.exist?(abs)
              pack_problems << "missing #{rel} (#{expected_id})"
              next
            end

            policy = by_path[real(abs)]
            unless policy
              pack_problems << "#{rel} (#{expected_id}) is not in the policies directory #{policies_dir}"
              next
            end

            if policy["id"].to_s != expected_id
              pack_problems << "#{rel} has policy id #{policy["id"].inspect}, recorded as #{expected_id.inspect}"
            end

            file_version = File.read(abs)[VERSION_HEADER, 1]&.strip&.delete('"')
            if file_version && file_version != version
              pack_problems << "#{rel} is from version #{file_version}, but #{version} is installed"
            end
          end

          problems << [name, version, pack_problems] if pack_problems.any?

          { "name" => name.to_s, "version" => version, "policy_ids" => files.map { |f| f["policy_id"].to_s } }
        end

        raise ValidationError, problems_message(problems, restore: true) if problems.any?

        packs
      end

      # Raises unless every policy a bundle's installed_packs lists is in the
      # bundle. Bundles from vkit 1.3.0 and older record only name and
      # version: those are checked against the pack this CLI ships, when it
      # ships that version.
      def check_bundle!(bundle)
        bundled = Array(bundle["policies"]).map { |p| p["id"].to_s }
        problems = []

        Array(bundle.dig("bundle", "installed_packs")).each do |pack|
          name = pack["name"].to_s
          version = pack["version"].to_s
          expected = pack["policy_ids"] || shipped_policy_ids(name, version)
          next unless expected

          missing = expected - bundled
          problems << [name, version, ["missing policies: #{missing.join(", ")}"]] if missing.any?
        end

        raise ValidationError, problems_message(problems, restore: false) if problems.any?
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      # Policy ids of the pack this CLI ships, or nil if it ships another version.
      def shipped_policy_ids(name, version)
        root = File.join(PACKS_DIR, name.to_s)
        meta_path = File.join(root, "metadata.yaml")
        return unless File.exist?(meta_path)

        meta = (YAML.safe_load(File.read(meta_path), aliases: true) || {})["__pack_meta"] || {}
        return unless meta["version"].to_s == version.to_s

        Dir.glob(File.join(root, "policies", "*.yaml")).sort.map do |file|
          (YAML.safe_load(File.read(file), aliases: true) || {})["id"].to_s
        end
      end

      def problems_message(problems, restore:)
        lines = problems.map do |name, version, list|
          "  #{name} #{version}:\n#{list.map { |p| "    - #{p}" }.join("\n")}"
        end

        hint =
          if restore
            "Restore the files with `vkit policy pack upgrade <pack>`, or remove the pack with " \
              "`vkit policy pack remove <pack> --force` if you no longer want it."
          else
            "Rebuild the bundle with `vkit policy bundle`, which checks the installed packs."
          end

        <<~MSG
          ❌ Installed policy packs are incomplete; the bundle would leave out their policies:

          #{lines.join("\n")}

          #{hint}
        MSG
      end
    end
  end
end
