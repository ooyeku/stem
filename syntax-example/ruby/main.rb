#!/usr/bin/env ruby
# Tiny todo CLI. Run with: ruby main.rb

class TodoList
  attr_reader :items

  def initialize
    @items = []
    @next_id = 1
  end

  def add(text, tags: [])
    item = { id: @next_id, text: text, tags: tags, done: false }
    @items << item
    @next_id += 1
    item
  end

  def complete(id)
    item = @items.find { |i| i[:id] == id }
    raise ArgumentError, "no such id: #{id}" unless item
    item[:done] = true
  end

  def pending
    @items.reject { |i| i[:done] }
  end

  def by_tag(tag)
    @items.select { |i| i[:tags].include?(tag) }
  end
end

list = TodoList.new
list.add("write stem docs", tags: %i[docs writing])
list.add("fix highlighter bug", tags: %i[bug urgent])
list.add("ship release", tags: %i[release])
list.complete(2)

puts "Pending:"
list.pending.each { |i| puts "  [#{i[:id]}] #{i[:text]} (#{i[:tags].join(', ')})" }

puts "\nUrgent items:"
list.by_tag(:urgent).each { |i| puts "  - #{i[:text]}" }
