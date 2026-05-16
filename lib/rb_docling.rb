# frozen_string_literal: true

# rb_docling - Pipeline di document understanding in Ruby
#
# Architettura ispirata a Docling (IBM Research) ma implementata in Ruby:
#   rpdfium  → estrazione testo + rendering pagine
#   onnxruntime → inferenza modelli (layout RT-DETR, TableFormer)
#   logica Ruby → reading order, document tree, hybrid chunker

require "rpdfium"

require_relative "rb_docling/version"
require_relative "rb_docling/document/bbox"
require_relative "rb_docling/document/node"
require_relative "rb_docling/document/tree"
require_relative "rb_docling/models/loader"
require_relative "rb_docling/layout/heuristic_layout"
require_relative "rb_docling/layout/onnx_layout"
require_relative "rb_docling/layout/reading_order"
require_relative "rb_docling/table/heuristic_table"
require_relative "rb_docling/table/onnx_tableformer"
require_relative "rb_docling/chunking/hybrid_chunker"
require_relative "rb_docling/pipeline"

module RbDocling
  class Error < StandardError; end

  # API top-level. Apre un PDF, lo processa, restituisce un DocumentTree.
  #
  #   tree = RbDocling.parse("doc.pdf")
  #   tree = RbDocling.parse("doc.pdf", layout: :onnx, table: :onnx)
  #   chunks = RbDocling::Chunking::HybridChunker.new.chunk(tree)
  def self.parse(path, layout: :heuristic, table: :heuristic, models_dir: default_models_dir)
    Pipeline.new(layout: layout, table: table, models_dir: models_dir).parse(path)
  end

  def self.default_models_dir
    File.expand_path("../../models", __dir__)
  end
end
