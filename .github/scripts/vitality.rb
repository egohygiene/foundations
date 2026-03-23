# frozen_string_literal: true

require "date"

# VitalityAuditor checks for stale TODOs to prevent technical debt.
class VitalityAuditor
  def initialize(days_threshold = 30)
    @threshold = days_threshold
    @errors = []
    @warnings = []
  end

  def audit_todos
    puts "### 🔍 Scanning Ruby files for TODOs..."

    Dir.glob("**/*.rb").each do |file|
      next if file.include?("vendor/") # Skip bundled gems

      File.readlines(file).each_with_index do |line, i|
        check_line(line, file, i + 1)
      end
    end
  end

  def report_and_exit
    puts "\n## 📊 Audit Results"

    @warnings.each { |w| puts w }

    if @errors.any?
      puts "\n### ❌ Vitality Check Failed"
      @errors.each { |e| puts "  - #{e}" }
      exit 1
    else
      puts "\n### ✅ Project is Fresh!"
      puts "All TODOs are within the #{@threshold}-day limit."
      exit 0
    end
  end

  private

  def check_line(line, file, line_num)
    if line =~ /TODO\(([\d\-]+)\)/
      date_added = Date.parse($1)
      if date_added < (Date.today - @threshold)
        @errors << "⏰ **Expired:** #{file}:#{line_num} (Added: #{date_added})"
      end
    elsif line.include?("TODO")
      @warnings << "⚠️  **Warning:** Undated TODO found in #{file}:#{line_num}"
    end
  end
end

auditor = VitalityAuditor.new(30)
auditor.audit_todos
auditor.report_and_exit
