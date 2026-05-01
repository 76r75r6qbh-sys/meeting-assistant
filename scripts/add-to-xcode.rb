#!/usr/bin/env ruby
# Add a file to Casablanca.xcodeproj.
#
# Usage:
#   scripts/add-to-xcode.rb <target> <relative-file-path> [<group-path>]
#
# Examples:
#   scripts/add-to-xcode.rb Casablanca Casablanca/Services/Updates/UpdateError.swift
#   scripts/add-to-xcode.rb CasablancaTests CasablancaTests/Updates/UpdateErrorTests.swift
#
# Idempotent: skips files already in the project.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Casablanca.xcodeproj', __dir__)
TARGET_NAME = ARGV[0] or abort("usage: #{$0} <target> <path> [<group-path>]")
FILE_PATH = ARGV[1] or abort("usage: #{$0} <target> <path> [<group-path>]")
GROUP_PATH = ARGV[2] # optional; defaults to inferring from path

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort("target '#{TARGET_NAME}' not found") unless target

# Skip if the file is already referenced.
existing = project.files.find { |f| f.path && File.expand_path(f.real_path.to_s) == File.expand_path(FILE_PATH) }
if existing
  puts "already in project: #{FILE_PATH}"
  exit 0
end

# Determine group: by default mirror the directory structure under the project root.
group_path = GROUP_PATH || File.dirname(FILE_PATH)

# Walk down to the right group, creating intermediate ones as needed.
group = project.main_group
group_path.split('/').each do |segment|
  next if segment == '.' || segment.empty?
  child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == segment }
  if child.nil?
    child = group.new_group(segment, segment)
  end
  group = child
end

file_ref = group.new_reference(File.basename(FILE_PATH))

# Decide whether to add to Sources, Resources, or Headers based on extension.
case File.extname(FILE_PATH)
when '.swift', '.m', '.mm', '.c', '.cpp'
  target.source_build_phase.add_file_reference(file_ref, true)
when '.zip', '.json', '.plist', '.xcassets', '.storyboard', '.xib', '.png', '.jpg', '.jpeg'
  target.resources_build_phase.add_file_reference(file_ref, true)
when '.h'
  # public headers handled elsewhere; no-op here
else
  # default to sources
  target.source_build_phase.add_file_reference(file_ref, true)
end

project.save
puts "added: #{FILE_PATH} → #{TARGET_NAME} (group: #{group_path})"
