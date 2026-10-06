#!/usr/bin/env ruby
# Adds Swift source files to the Casablanca Xcode project (classic, non-synchronized groups).
#
# Usage:
#   ruby scripts/add-files-to-xcodeproj.rb <file1.swift> <file2.swift> ...
#
# Routing:
#   - Paths under "CasablancaTests/" are added to the CasablancaTests target.
#   - All other paths are added to the Casablanca app target.
# Group hierarchy mirrors the on-disk folder path. Idempotent: a file already
# referenced in the project is skipped. Files must already exist on disk.

require "xcodeproj"
require "pathname"

PROJECT_PATH = "Casablanca.xcodeproj"

proj = Xcodeproj::Project.open(PROJECT_PATH)
app_target  = proj.targets.find { |t| t.name == "Casablanca" }
test_target = proj.targets.find { |t| t.name == "CasablancaTests" }
raise "targets not found" unless app_target && test_target

# Find or create a nested PBXGroup matching the given path components, starting
# from the project's main group, reusing existing groups by name/path.
def group_for(proj, components)
  group = proj.main_group
  components.each do |name|
    existing = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && (c.display_name == name || c.path == name) }
    group = existing || group.new_group(name, name)
  end
  group
end

added = []
skipped = []

ARGV.each do |arg|
  path = Pathname.new(arg).cleanpath
  raise "no such file: #{path}" unless File.exist?(path)

  rel = path.to_s
  already = proj.files.any? { |f| f.real_path.to_s == File.expand_path(rel) }
  if already
    skipped << rel
    next
  end

  comps = path.each_filename.to_a
  is_test = comps.first == "CasablancaTests"
  target = is_test ? test_target : app_target

  # Group path = directory components (everything except the filename).
  dir_comps = comps[0...-1]
  group = group_for(proj, dir_comps)

  file_ref = group.new_reference(File.expand_path(rel))
  file_ref.set_source_tree("SOURCE_ROOT")
  file_ref.set_path(rel)
  target.add_file_references([file_ref])
  added << rel
end

proj.save
puts "Added (#{added.size}): #{added.join(', ')}" unless added.empty?
puts "Skipped already-present (#{skipped.size}): #{skipped.join(', ')}" unless skipped.empty?
puts "Done."
