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

section "ReadingOrder strategies"

BB = RbDocling::Document::BBox

def mock_block(idx, x0:, top:, x1: nil, bottom: nil, text: "block#{idx}", **extra)
  x1 ||= x0 + 100
  bottom ||= top + 20
  {
    type: :text,
    text: text,
    bbox: BB.new(x0: x0, top: top, x1: x1, bottom: bottom)
  }.merge(extra)
end

# Mock minimo di Page + Tree + Element per testare sort_by_struct_tree
# senza dover generare un PDF tagged a runtime (complesso e fragile).
class MockObj
  attr_reader :address
  def initialize(address) = (@address = address)
end

class MockElement
  attr_reader :marked_content_ids, :children
  def initialize(mcids: [], children: [])
    @marked_content_ids = mcids
    @children = children
  end

  def walk(&block)
    return enum_for(:walk) unless block
    yield self
    @children.each { |c| c.walk(&block) }
  end
end

class MockTree
  attr_reader :root_count
  def initialize(roots:, empty: false)
    @roots = roots
    @empty = empty
  end
  def empty? = @empty
  def walk(&block)
    return enum_for(:walk) unless block
    @roots.each { |r| r.walk(&block) }
  end
end

class MockPage
  def initialize(chars:, regions:, tree:)
    @chars = chars
    @regions = regions
    @tree = tree
  end
  def chars = @chars
  def marked_content_regions = @regions
  def struct_tree
    if block_given?
      yield @tree
    else
      @tree
    end
  end
end

# Helper: char con text_obj_id + bbox
def mock_char(text_obj_id:, x:, y:)
  {
    text_obj_id: text_obj_id,
    x0: x, x1: x + 5,
    top: y, bottom: y + 10
  }
end

# T1: struct-tree riordina secondo i tag, ignorando l'ordine geometrico
# Scenario: tre blocchi, ordinati geometricamente sarebbero A→B→C ma il
# tagged PDF dichiara ordine C→A→B.
obj_a = MockObj.new(0xA000)
obj_b = MockObj.new(0xB000)
obj_c = MockObj.new(0xC000)
chars_t1 = [
  # Blocco A copre (0,0)-(100,20)
  mock_char(text_obj_id: 0xA000, x: 10, y: 5),
  # Blocco B copre (0,50)-(100,70)
  mock_char(text_obj_id: 0xB000, x: 10, y: 55),
  # Blocco C copre (0,100)-(100,120)
  mock_char(text_obj_id: 0xC000, x: 10, y: 105)
]
regions_t1 = { 10 => [obj_a], 20 => [obj_b], 30 => [obj_c] }
# Tree dichiara ordine: C (mcid 30) prima, poi A (mcid 10), poi B (mcid 20)
tree_t1 = MockTree.new(roots: [
  MockElement.new(mcids: [30]),
  MockElement.new(mcids: [10]),
  MockElement.new(mcids: [20])
])
page_t1 = MockPage.new(chars: chars_t1, regions: regions_t1, tree: tree_t1)
blocks_t1 = [
  mock_block("A", x0: 0, top: 0, bottom: 20),
  mock_block("B", x0: 0, top: 50, bottom: 70),
  mock_block("C", x0: 0, top: 100, bottom: 120)
]
ordered_t1 = RbDocling::Layout::ReadingOrder.sort(blocks_t1, page: page_t1)
assert ordered_t1[0][:text] == "blockC", "T1: struct-tree mette C per primo"
assert ordered_t1[1][:text] == "blockA", "T1: A secondo"
assert ordered_t1[2][:text] == "blockB", "T1: B terzo"

# T2: tree vuoto → fallback geometric, ordine top-to-bottom
empty_tree = MockTree.new(roots: [], empty: true)
page_t2 = MockPage.new(chars: [], regions: {}, tree: empty_tree)
blocks_t2 = [
  mock_block("Z", x0: 0, top: 100, bottom: 120),
  mock_block("Y", x0: 0, top: 50, bottom: 70),
  mock_block("X", x0: 0, top: 0, bottom: 20)
]
ordered_t2 = RbDocling::Layout::ReadingOrder.sort(blocks_t2, page: page_t2)
assert ordered_t2.map { |b| b[:text] } == %w[blockX blockY blockZ],
       "T2: tree empty → fallback geometric top-to-bottom"

# T3: pagina untagged (tree nil) → fallback geometric
page_t3 = MockPage.new(chars: [], regions: {}, tree: nil)
ordered_t3 = RbDocling::Layout::ReadingOrder.sort(blocks_t2, page: page_t3)
assert ordered_t3.map { |b| b[:text] } == %w[blockX blockY blockZ],
       "T3: tree nil → fallback geometric"

# T4: blocco orfano (no MCID match) → accodato dopo i blocchi con tag
chars_t4 = [
  mock_char(text_obj_id: 0xA000, x: 10, y: 5),
  mock_char(text_obj_id: 0xB000, x: 10, y: 55)
  # nessun char per blocco C → C resta orfano
]
regions_t4 = { 10 => [MockObj.new(0xA000)], 20 => [MockObj.new(0xB000)] }
tree_t4 = MockTree.new(roots: [
  MockElement.new(mcids: [10]),
  MockElement.new(mcids: [20])
])
page_t4 = MockPage.new(chars: chars_t4, regions: regions_t4, tree: tree_t4)
blocks_t4 = [
  mock_block("A", x0: 0, top: 0, bottom: 20),
  mock_block("B", x0: 0, top: 50, bottom: 70),
  mock_block("C-orphan", x0: 0, top: 100, bottom: 120) # no char in bbox
]
ordered_t4 = RbDocling::Layout::ReadingOrder.sort(blocks_t4, page: page_t4)
assert ordered_t4.map { |b| b[:text] } == %w[blockA blockB blockC-orphan],
       "T4: orfano (no MCID) accodato dopo i blocchi con tag"

# T5: strategy: :geometric forzato → bypassa struct-tree anche se presente
ordered_t5 = RbDocling::Layout::ReadingOrder.sort(blocks_t1, page: page_t1, strategy: :geometric)
# Geometric col1 top→bottom: A, B, C (ignora il tree)
assert ordered_t5.map { |b| b[:text] } == %w[blockA blockB blockC],
       "T5: strategy: :geometric bypassa struct-tree"

# T6: backward-compat → ReadingOrder.sort(blocks) senza kwargs come prima
ordered_t6 = RbDocling::Layout::ReadingOrder.sort(blocks_t1)
assert ordered_t6.map { |b| b[:text] } == %w[blockA blockB blockC],
       "T6: backward-compat sort(blocks) → geometric"

# T7: sort_by_ml usa :detection_index
blocks_t7 = [
  mock_block("D2", x0: 0, top: 50, bottom: 70, detection_index: 2),
  mock_block("D0", x0: 0, top: 100, bottom: 120, detection_index: 0),
  mock_block("D1", x0: 0, top: 0, bottom: 20, detection_index: 1)
]
ordered_t7 = RbDocling::Layout::ReadingOrder.sort(blocks_t7, ml_output: blocks_t7, strategy: :ml)
assert ordered_t7.map { |b| b[:text] } == %w[blockD0 blockD1 blockD2],
       "T7: ML strategy ordina per detection_index"

section "Pipeline ONNX (se modello presente)"
models_dir = File.expand_path("../models", __dir__)
if File.exist?(File.join(models_dir, "layout.onnx"))
  tree_onnx = RbDocling.parse(pdf, layout: :onnx, models_dir: models_dir)
  assert tree_onnx.is_a?(RbDocling::Document::Tree), "ONNX pipeline produce un tree"
  assert !tree_onnx.nodes.empty?, "ONNX tree non vuoto"

  # Verifica che il pipeline ONNX produca davvero detection del layout (non solo
  # nodi tabella ereditati dall'heuristic). Il bug noto era: il modello emette
  # `logits` (raw scores per query) invece di `labels` (argmax pre-calcolato),
  # e l'estrattore non sapeva interpretarli → output con sole tabelle heuristic.
  non_table_nodes = tree_onnx.nodes.reject { |n| n.type == :table }
  assert !non_table_nodes.empty?,
         "ONNX pipeline produce detection oltre alle tabelle " \
         "(regression test per bug logits non gestiti)"

  # Verifica che almeno un nodo abbia uno score (proviene dal layout ML)
  assert tree_onnx.nodes.any? { |n| n.metadata[:score] },
         "almeno una detection ha metadata[:score] dal modello ML"
else
  puts "  (skip: nessun modello ONNX in #{models_dir})"
end

# Test unit di OnnxLayout#extract_from_logits indipendentemente dal modello.
# Verifica che logits+pred_boxes vengano correttamente convertiti in
# labels/boxes/scores via argmax + sigmoid.
section "OnnxLayout extract_from_logits"
# Costruisco una OnnxLayout senza model (uso send per il metodo privato)
if File.exist?(File.join(models_dir, "layout.onnx"))
  layout_engine = RbDocling::Layout::OnnxLayout.new(
    model_path: File.join(models_dir, "layout.onnx")
  )

  # Simulo output di 3 query con logits dummy
  fake_logits = [[
    [-5.0, -3.0, -1.0, 8.0,  -2.0, 0.0,  1.0, -1.0, -3.0, -2.0, -4.0], # argmax=3, sigmoid(8)~1.0
    [2.0,  -1.0, -2.0, -3.0, -1.0, -2.0, 0.0, -1.0, -2.0, -3.0, -2.0], # argmax=0, sigmoid(2)~0.88
    [-10.0]*11 # tutti molto bassi
  ]]
  fake_logits[0][2][0] = -8.0 # già: argmax=0 con score sigmoid(-8) molto basso

  fake_boxes = [[
    [0.5, 0.1, 0.4, 0.05],
    [0.5, 0.3, 0.6, 0.08],
    [0.5, 0.5, 0.5, 0.1]
  ]]

  labels, boxes, scores = layout_engine.send(:extract_from_logits, fake_logits, fake_boxes)
  assert labels == [3, 0, 0], "argmax corretto su 3 query"
  assert scores[0] > 0.999, "sigmoid(8) ≈ 1.0"
  assert scores[1] > 0.85 && scores[1] < 0.92, "sigmoid(2) ≈ 0.88"
  assert scores[2] < 0.01, "sigmoid(-8) ≈ 0"
  assert boxes.size == 3, "boxes inalterati"
end

puts ""
if @failures.zero?
  puts "#{PASS} #{@tests} test passati"
  exit 0
else
  puts "#{FAIL} #{@failures}/#{@tests} test falliti"
  exit 1
end
