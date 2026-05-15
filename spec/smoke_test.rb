#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke test minimale (senza rspec, eseguibile direttamente).
# Esercita le componenti core su PDF di test generati a runtime.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rb_docling"

PASS = "\e[32m✓\e[0m"
FAIL = "\e[31m✗\e[0m"

@failures = 0
@tests = 0

def assert(cond, msg)
  @tests += 1
  if cond
    puts "#{PASS} #{msg}"
  else
    puts "#{FAIL} #{msg}"
    @failures += 1
  end
end

def section(name)
  puts "\n=== #{name} ==="
end

pdf = ARGV[0] || File.expand_path("fixtures/01_simple.pdf", __dir__)
unless File.exist?(pdf)
  abort "PDF test non trovato: #{pdf}. Eseguire prima gen_test_pdf.py oppure passare un path."
end

section "BBox value object"
b1 = RbDocling::Document::BBox.new(x0: 0, top: 0, x1: 100, bottom: 50)
b2 = RbDocling::Document::BBox.new(x0: 10, top: 10, x1: 30, bottom: 30)
b3 = RbDocling::Document::BBox.new(x0: 200, top: 0, x1: 300, bottom: 50)
assert b1.width == 100, "width"
assert b1.height == 50, "height"
assert b1.contains?(b2), "contains nested"
assert !b1.contains?(b3), "does not contain disjoint"
assert b1.iou(b2).positive?, "iou positive on overlap"
assert b1.iou(b3).zero?, "iou zero on disjoint"

section "Pipeline heuristic"
tree = RbDocling.parse(pdf)
assert !tree.nodes.empty?, "tree has nodes"
assert tree.metadata[:page_count].positive?, "metadata has page_count"
assert tree.nodes.any? { |n| n.type == :title || n.type == :section_header }, "has at least one heading"
assert tree.nodes.any? { |n| n.type == :text }, "has at least one text"
if tree.metadata[:page_count] == 1
  assert tree.nodes.any? { |n| n.type == :table }, "has at least one table"
end

section "Document tree headings_path"
heading_idx = tree.nodes.index { |n| n.type == :section_header || n.type == :title }
if heading_idx
  path = tree.headings_path_for(heading_idx)
  assert path.is_a?(Array), "headings_path returns array"
end

section "HybridChunker"
chunker = RbDocling::Chunking::HybridChunker.new(max_tokens: 200, min_tokens: 30)
chunks = chunker.chunk(tree)
assert chunks.is_a?(Array), "chunks is array"
assert !chunks.empty?, "at least one chunk"
chunks.each_with_index do |c, i|
  assert c[:token_count] <= 200, "chunk #{i} respects max_tokens"
  assert c[:text].is_a?(String) && !c[:text].empty?, "chunk #{i} has text"
  assert c[:metadata].key?(:heading_id), "chunk #{i} has heading_id"
end

section "Splitting (chunk grande)"
big_tree = RbDocling::Document::Tree.new(nodes: [
  RbDocling::Document::Node.new(
    type: :text,
    text: "Frase " * 500, # ~2500 char ≈ 625 token
    page_no: 1
  )
])
big_chunks = RbDocling::Chunking::HybridChunker.new(max_tokens: 100).chunk(big_tree)
assert big_chunks.size > 1, "chunk grande viene spezzato"
assert big_chunks.all? { |c| c[:token_count] <= 100 }, "tutti gli split sotto max"

section "Merging (chunks piccoli)"
small_tree = RbDocling::Document::Tree.new(nodes: [
  RbDocling::Document::Node.new(type: :section_header, text: "Sec A", level: 2, page_no: 1),
  RbDocling::Document::Node.new(type: :text, text: "Breve a.", page_no: 1),
  RbDocling::Document::Node.new(type: :text, text: "Breve b.", page_no: 1)
])
small_chunks = RbDocling::Chunking::HybridChunker.new(max_tokens: 200, min_tokens: 50).chunk(small_tree)
assert small_chunks.size <= 2, "chunks piccoli adiacenti vengono fusi"

section "Pipeline ONNX (se modello presente)"
models_dir = "/home/claude/rb_docling/models"
if File.exist?(File.join(models_dir, "layout.onnx"))
  tree_onnx = RbDocling.parse(pdf, layout: :onnx, models_dir: models_dir)
  assert tree_onnx.is_a?(RbDocling::Document::Tree), "ONNX pipeline produce un tree"
  assert !tree_onnx.nodes.empty?, "ONNX tree non vuoto"
else
  puts "  (skip: nessun modello ONNX in #{models_dir})"
end

puts ""
if @failures.zero?
  puts "#{PASS} #{@tests} test passati"
  exit 0
else
  puts "#{FAIL} #{@failures}/#{@tests} test falliti"
  exit 1
end
