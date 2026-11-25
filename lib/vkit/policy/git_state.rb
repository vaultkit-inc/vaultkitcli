# frozen_string_literal: true

require "open3"
require "pathname"

module Vkit
  module Policy
    # The git state of a policy project, for a bundle's version and source.
    # A bundle's version is the commit its policies were committed in, so it
    # can be traced back to them; that only holds when nothing the bundle
    # reads has changed since that commit.
    class GitState
      attr_reader :root

      def initialize(root)
        @root = root
      end

      def repo?
        git("rev-parse", "--is-inside-work-tree").first == "true"
      end

      # nil in a repo with no commits yet.
      def head
        out, ok = git("rev-parse", "--verify", "--quiet", "HEAD")
        ok && !out.empty? ? out : nil
      end

      def branch
        out, ok = git("rev-parse", "--abbrev-ref", "HEAD")
        ok && !out.empty? && out != "HEAD" ? out : nil
      end

      def remote_url
        out, ok = git("config", "--get", "remote.origin.url")
        ok && !out.empty? ? out : nil
      end

      # Files under `paths` that differ from HEAD: modified, staged, new,
      # deleted, or ignored by .gitignore (they'd be bundled but never
      # committed). [{ path:, ignored: }], with paths relative to `root`.
      def uncommitted(paths)
        existing = paths.select { |p| File.exist?(File.join(root, p)) }
        return [] if existing.empty?

        out, ok = git_raw("status", "--porcelain=v1", "--untracked-files=all", "--ignored=traditional", "--", *existing)
        raise "git status failed in #{root}" unless ok

        out.lines.map(&:chomp).reject(&:empty?).map do |line|
          path = line[3..].sub(/\A"(.*)"\z/, '\1').split(" -> ").last.chomp("/")
          { path: from_root(path), ignored: line.start_with?("!!") }
        end
      end

      private

      # git status prints paths relative to the repository's top level, which
      # isn't `root` when the policy project is a subfolder of a bigger repo.
      def from_root(path)
        top, = git("rev-parse", "--show-toplevel")
        Pathname.new(File.join(File.realpath(top), path))
                .relative_path_from(Pathname.new(File.realpath(root))).to_s
      end

      # [stripped stdout, success?], for commands that print one value.
      def git(*args)
        out, ok = git_raw(*args)
        [out.strip, ok]
      end

      # [stdout, success?] as printed: `git status --porcelain` lines start
      # with a status column that may be a space. Never raises when git is
      # missing.
      def git_raw(*args)
        out, _err, status = Open3.capture3("git", *args, chdir: root)
        [out, status.success?]
      rescue SystemCallError
        ["", false]
      end
    end
  end
end
