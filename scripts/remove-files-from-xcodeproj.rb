#!/usr/bin/env ruby
# Removes source files from the Casablanca Xcode project (classic, non-synchronized groups).
#
# Usage:
#   ruby scripts/remove-files-from-xcodeproj.rb <file1.swift> <file2.swift> ...
#
# For each path, drops its build-file entries from every target (Casablanca and
# CasablancaTests) and removes the file reference from its group. Groups left
# empty by the removal are deleted too. Does not touch the file on disk (use
# `git rm` for that). Idempotent: a path not referenced in the project is skipped.

require "xcodeproj"
require "pathname"

# project.pbxproj holds non-ASCII bytes; don't depend on the shell's locale.
Encoding.default_external = Encoding::UTF_8

PROJECT_PATH = "Casablanca.xcodeproj"

proj = Xcodeproj::Project.open(PROJECT_PATH)
app_target  = proj.targets.find { |t| t.name == "Casablanca" }
test_target = proj.targets.find { |t| t.name == "CasablancaTests" }
raise "targets not found" unless app_target && test_target

# Delete `group` and then each ancestor that is left empty, stopping at the
# project's main group.
def prune_empty_groups(proj, group)
  while group && group != proj.main_group && group.children.empty?
    parent = group.parent
    group.remove_from_project
    group = parent.is_a?(Xcodeproj::Project::Object::PBXGroup) ? parent : nil
  end
end

removed = []
skipped = []

ARGV.each do |arg|
  rel = Pathname.new(arg).cleanpath.to_s
  abs = File.expand_path(rel)

  refs = proj.files.select { |f| f.real_path.to_s == abs }
  if refs.empty?
    skipped << rel
    next
  end

  refs.each do |ref|
    [app_target, test_target].each do |target|
      target.build_phases.each do |phase|
        phase.files.select { |bf| bf.file_ref == ref }.each { |bf| phase.remove_build_file(bf) }
      end
    end
    group = ref.parent
    ref.remove_from_project
    prune_empty_groups(proj, group) if group.is_a?(Xcodeproj::Project::Object::PBXGroup)
  end
  removed << rel
end

proj.save
puts "Removed (#{removed.size}): #{removed.join(', ')}" unless removed.empty?
puts "Skipped not-present (#{skipped.size}): #{skipped.join(', ')}" unless skipped.empty?
puts "Done."
