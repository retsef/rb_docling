# frozen_string_literal: true

require "bundler/gem_tasks"

# Carica tasks "models:*" per scaricare i pesi ONNX di Docling.
require_relative "lib/rb_docling/rake_tasks"
RbDocling::RakeTasks.install

desc "Esegue lo smoke test (richiede PDFIUM_LIBRARY_PATH e un PDF di test)"
task :test do
  pdf = ENV["PDF"] || File.expand_path("spec/fixtures/test.pdf", __dir__)
  unless File.exist?(pdf)
    abort "PDF di test non trovato: #{pdf}. Passa PDF=/path/to/file.pdf"
  end
  unless ENV["PDFIUM_LIBRARY_PATH"]
    warn "Avviso: PDFIUM_LIBRARY_PATH non impostato. Lo smoke test fallirà se rpdfium non riesce a caricare libpdfium."
  end
  ruby "-I lib spec/smoke_test.rb #{pdf}"
end

task default: :test
