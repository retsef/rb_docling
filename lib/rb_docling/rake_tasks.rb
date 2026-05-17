# frozen_string_literal: true

require "rake"
require "net/http"
require "uri"
require "fileutils"
require "digest"
require "json"

module RbDocling
  # Rake tasks per scaricare e gestire i modelli ONNX di Docling.
  #
  # I .onnx ufficiali NON sono disponibili sui repo HuggingFace di IBM/ds4sd
  # (che pubblica solo PyTorch). rb_docling usa un repo dedicato di conversioni
  # pre-compilate; lo script che le genera è in `tools/` (vedi tools/README.md).
  #
  # Uso (in un Rakefile):
  #
  #   require "rb_docling/rake_tasks"
  #   RbDocling::RakeTasks.install
  #
  # Tasks esposti:
  #   models:fetch              # scarica tutti i modelli (layout + tableformer)
  #   models:fetch:layout       # solo layout (DocLayNet Heron RT-DETR)
  #   models:fetch:tableformer  # solo TableFormer (encoder + decoder + vocab)
  #   models:list               # elenca i file modello attesi e il loro stato
  #   models:clean              # rimuove i .onnx scaricati
  #
  # Override (env var):
  #   RB_DOCLING_HF_REPO=scinoky/rb-docling-onnx     # repo HuggingFace di default
  #   RB_DOCLING_HF_REVISION=main                       # branch/tag/commit
  #   RB_DOCLING_LAYOUT_URL=https://...                 # URL completa per file singolo
  #   RB_DOCLING_TF_ENCODER_URL=...
  #   RB_DOCLING_TF_DECODER_URL=...
  #   RB_DOCLING_TF_VOCAB_URL=...
  #   RB_DOCLING_MODELS_DIR=./custom/path               # default: ./models
  #   FORCE=1                                           # riscarica anche se presente
  module RakeTasks
    # Repo HuggingFace che ospita i .onnx pre-convertiti.
    # I file sono prodotti dagli script in `tools/`.
    DEFAULT_HF_REPO     = "scinoky/rb_docling-onnx"
    DEFAULT_HF_REVISION = "main"

    SOURCES = {
      layout: {
        hf_path:     "layout.onnx",
        filename:    "layout.onnx",
        description: "DocLayNet Heron RT-DETR layout detector",
        url_env:     "RB_DOCLING_LAYOUT_URL"
      },
      tableformer_encoder: {
        hf_path:     "tableformer_encoder.onnx",
        filename:    "tableformer_encoder.onnx",
        description: "TableFormer encoder (accurate variant)",
        url_env:     "RB_DOCLING_TF_ENCODER_URL"
      },
      tableformer_decoder: {
        hf_path:     "tableformer_decoder_step.onnx",
        filename:    "tableformer_decoder_step.onnx",
        description: "TableFormer decoder single-step (loop autoregressivo in Ruby)",
        url_env:     "RB_DOCLING_TF_DECODER_URL"
      },
      tableformer_vocab: {
        hf_path:     "tableformer_vocab.json",
        filename:    "tableformer_vocab.json",
        description: "TableFormer OTSL vocabulary (richiesto dal decoder)",
        url_env:     "RB_DOCLING_TF_VOCAB_URL"
      },
      tableformer_tm_config: {
        hf_path:     "tableformer_tm_config.json",
        filename:    "tableformer_tm_config.json",
        description: "TableFormer config originale ds4sd (word_map_cell, predict params)",
        url_env:     "RB_DOCLING_TF_CONFIG_URL"
      }
    }.freeze

    module_function

    def install
      extend Rake::DSL
      namespace :models do
        desc "Scarica tutti i modelli ONNX di Docling (layout + tableformer + vocab)"
        task fetch: %w[fetch:layout fetch:tableformer]

        namespace :fetch do
          desc "Scarica il modello layout (DocLayNet Heron RT-DETR)"
          task :layout do
            fetch_one(:layout)
          end

          desc "Scarica TableFormer completo (encoder + decoder_step + vocab + tm_config)"
          task tableformer: %i[tableformer_encoder tableformer_decoder
                               tableformer_vocab tableformer_tm_config]

          desc "Scarica solo il TableFormer encoder"
          task :tableformer_encoder do
            fetch_one(:tableformer_encoder)
          end

          desc "Scarica solo il TableFormer decoder"
          task :tableformer_decoder do
            fetch_one(:tableformer_decoder)
          end

          desc "Scarica il vocab OTSL di TableFormer (richiesto dal decoder)"
          task :tableformer_vocab do
            fetch_one(:tableformer_vocab)
          end

          desc "Scarica il tm_config.json originale di TableFormer"
          task :tableformer_tm_config do
            fetch_one(:tableformer_tm_config)
          end
        end

        desc "Elenca i modelli attesi e il loro stato (presente/mancante)"
        task :list do
          list_models
        end

        desc "Rimuove tutti i modelli scaricati in #{models_dir}"
        task :clean do
          clean_models
        end
      end
    end

    # --- Implementazione -----------------------------------------------

    def fetch_one(key)
      spec = SOURCES.fetch(key) { abort "Modello sconosciuto: #{key}" }
      url = url_for(key, spec)
      dest = File.join(models_dir, spec[:filename])

      FileUtils.mkdir_p(models_dir)

      if File.exist?(dest) && !ENV["FORCE"]
        puts "[skip] #{spec[:filename]} esiste già (#{format_size(File.size(dest))}). " \
             "Usa FORCE=1 per riscaricare."
        return
      end

      puts "[fetch] #{spec[:description]}"
      puts "        from: #{url}"
      puts "        to:   #{dest}"
      download(url, dest)
      puts "        ok:   #{format_size(File.size(dest))}"
    rescue StandardError => e
      warn "[error] download fallito per #{key}: #{e.message}"
      warn "        Suggerimento: scaricalo manualmente e posizionalo in #{dest}"
      warn "        oppure punta a una URL alternativa: #{spec[:url_env]}=https://..."
      warn "        oppure cambia repo HF: RB_DOCLING_HF_REPO=user/repo"
      raise
    end

    def list_models
      puts "Models directory: #{models_dir}"
      puts "HF source:        #{hf_repo}@#{hf_revision}"
      puts ""
      SOURCES.each do |key, spec|
        path = File.join(models_dir, spec[:filename])
        if File.exist?(path)
          puts "  [ok]      #{spec[:filename].ljust(32)} #{format_size(File.size(path))}  #{spec[:description]}"
        else
          puts "  [missing] #{spec[:filename].ljust(32)} #{'-'.ljust(10)}  #{spec[:description]}"
          puts "            override: #{spec[:url_env]}=https://..."
        end
      end
      puts ""
      missing = SOURCES.reject { |_, s| File.exist?(File.join(models_dir, s[:filename])) }
      if missing.empty?
        puts "Tutti i modelli presenti."
      else
        puts "#{missing.size}/#{SOURCES.size} modelli mancanti. Lancia `rake models:fetch` per scaricarli."
      end
    end

    def clean_models
      removed = 0
      SOURCES.each_value do |spec|
        path = File.join(models_dir, spec[:filename])
        next unless File.exist?(path)

        File.delete(path)
        puts "[rm] #{path}"
        removed += 1
      end
      puts "Rimossi #{removed} file."
    end

    def models_dir
      ENV["RB_DOCLING_MODELS_DIR"] || File.expand_path("models", Dir.pwd)
    end

    def hf_repo
      ENV["RB_DOCLING_HF_REPO"] || DEFAULT_HF_REPO
    end

    def hf_revision
      ENV["RB_DOCLING_HF_REVISION"] || DEFAULT_HF_REVISION
    end

    # URL effettiva per un modello. Priorità:
    #   1. URL completa via env var (es. RB_DOCLING_LAYOUT_URL=https://...)
    #   2. Costruita da hf_repo + hf_revision + hf_path
    def url_for(_key, spec)
      override = ENV[spec[:url_env]]
      return override if override && !override.empty?

      "https://huggingface.co/#{hf_repo}/resolve/#{hf_revision}/#{spec[:hf_path]}"
    end

    # Download HTTP con follow di redirect (HuggingFace risponde 302 verso CDN).
    # Stream su disco con progress su stderr ogni 5 MB.
    def download(url, dest, max_redirects: 6)
      uri = URI(url)
      max_redirects.times do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(Net::HTTP::Get.new(uri)) do |res|
            case res
            when Net::HTTPSuccess
              return stream_to_file(res, dest)
            when Net::HTTPRedirection
              uri = URI(res["location"])
              break # ricomincia con nuova URI
            else
              raise "HTTP #{res.code} #{res.message}"
            end
          end
        end
      end
      raise "Too many redirects (>#{max_redirects})"
    end

    def stream_to_file(res, dest)
      total = res["content-length"]&.to_i
      tmp = "#{dest}.partial"
      written = 0
      last_log = 0
      File.open(tmp, "wb") do |f|
        res.read_body do |chunk|
          f.write(chunk)
          written += chunk.bytesize
          if written - last_log > 5 * 1024 * 1024
            pct = total&.positive? ? " (#{(100.0 * written / total).round(1)}%)" : ""
            warn "        #{format_size(written)}#{pct}"
            last_log = written
          end
        end
      end
      File.rename(tmp, dest)
    end

    def format_size(bytes)
      units = %w[B KB MB GB]
      i = 0
      v = bytes.to_f
      while v >= 1024 && i < units.size - 1
        v /= 1024
        i += 1
      end
      format("%.1f %s", v, units[i])
    end
  end
end
