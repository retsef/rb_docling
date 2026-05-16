# frozen_string_literal: true

require_relative "lib/rb_docling/version"

Gem::Specification.new do |spec|
  spec.name        = "rb_docling"
  spec.version     = RbDocling::VERSION
  spec.authors     = ["Roberto Scinocca"]
  spec.email       = ["roberto.scinocca@hey.com"]

  spec.summary     = "Document understanding pipeline in Ruby (PDF → structured tree → RAG chunks)."
  spec.description = <<~DESC
    rb_docling è una pipeline di document understanding nativa Ruby ispirata a
    Docling (IBM Research). Estrae testo + bbox da PDF via rpdfium, esegue
    layout analysis (heuristic o ONNX RT-DETR), table structure (heuristic o
    TableFormer), reading order multi-strato (PDF Structure Tree → ML →
    geometric) e produce DocumentTree + chunks per RAG.
  DESC
  spec.homepage    = "https://github.com/retsef/rb_docling"
  spec.license     = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "homepage_uri"      => spec.homepage,
    "source_code_uri"   => spec.homepage,
    "bug_tracker_uri"   => "#{spec.homepage}/issues",
    "changelog_uri"     => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/*",
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "CLAUDE.md",
    "docs/**/*.md"
  ].select { |f| File.file?(f) }

  spec.bindir      = "bin"
  spec.executables = ["rb_docling"]
  spec.require_paths = ["lib"]

  # Dipendenze runtime
  spec.add_dependency "rpdfium",     "~> 0.3", ">= 0.3.13"
  spec.add_dependency "onnxruntime", "~> 0.11"

  # Dipendenze di sviluppo: tutto opzionale, non scaricato dal consumer della gem
  spec.add_development_dependency "rake", "~> 13.0"
end
