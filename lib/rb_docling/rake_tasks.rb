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
  # Uso (in un Rakefile):
  #
  #   require "rb_docling/rake_tasks"
  #   RbDocling::RakeTasks.install
  #
  # Tasks esposti:
  #   models:fetch              # scarica tutti i modelli (layout + tableformer)
  #   models:fetch:layout       # solo layout (DocLayNet RT-DETR)
  #   models:fetch:tableformer  # solo TableFormer (encoder + decoder)
  #   models:list               # elenca i file modello attesi e il loro stato
  #   models:clean              # rimuove i .onnx scaricati
  #
  # Override delle URL via env var:
  #   RB_DOCLING_LAYOUT_URL=https://...     rake models:fetch:layout
  #   RB_DOCLING_TF_ENCODER_URL=https://...
  #   RB_DOCLING_TF_DECODER_URL=https://...
  #   RB_DOCLING_MODELS_DIR=./custom/path   (default: ./models)
  module RakeTasks
    # Sorgenti note. Documentate ma NON garantite — le release ONNX di
    # Docling cambiano spesso. Override via env var (vedi sopra) se le URL
    # non rispondono o se vuoi puntare a una variante diversa.
    #
    # IMPORTANT (CLAUDE.md/honest scaffolding): queste URL sono PLACEHOLDER
    # ragionevoli basati su repository pubblici HuggingFace; vanno verificate
    # all'uso. Se i download falliscono, l'utente deve scaricare manualmente
    # i file e posizionarli in `models/` con i nomi attesi (vedi models:list).
    SOURCES = {
      layout: {
        url: "https://huggingface.co/ds4sd/docling-layout-heron-101/resolve/main/model.onnx",
        filename: "layout.onnx",
        description: "DocLayNet RT-DETR layout detector (Heron-101 variant)"
      },
      tableformer_encoder: {
        url: "https://huggingface.co/ds4sd/docling-tableformer-accurate/resolve/main/encoder.onnx",
        filename: "tableformer_encoder.onnx",
        description: "TableFormer encoder (accurate variant)"
      },
      tableformer_decoder: {
        url: "https://huggingface.co/ds4sd/docling-tableformer-accurate/resolve/main/decoder.onnx",
        filename: "tableformer_decoder.onnx",
        description: "TableFormer decoder (autoregressive, OTSL vocabulary)"
      }
    }.freeze

    module_function

    def install
      extend Rake::DSL
      namespace :models do
        desc "Scarica tutti i modelli ONNX di Docling (layout + tableformer)"
        task fetch: %w[fetch:layout fetch:tableformer]

        namespace :fetch do
          desc "Scarica il modello layout (DocLayNet RT-DETR)"
          task :layout do
            fetch_one(:layout)
          end

          desc "Scarica i modelli TableFormer (encoder + decoder)"
          task tableformer: %i[tableformer_encoder tableformer_decoder]

          desc "Scarica solo il TableFormer encoder"
          task :tableformer_encoder do
            fetch_one(:tableformer_encoder)
          end

          desc "Scarica solo il TableFormer decoder"
          task :tableformer_decoder do
            fetch_one(:tableformer_decoder)
          end
        end

        desc "Elenca i modelli attesi e il loro stato (presente/mancante)"
        task :list do
          list_models
        end

        desc "Rimuove tutti i .onnx scaricati in #{models_dir}"
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
      warn "        oppure passa una URL alternativa via env var (vedi rake -D models:fetch:#{key})"
      raise
    end

    def list_models
      puts "Models directory: #{models_dir}"
      puts ""
      SOURCES.each do |key, spec|
        path = File.join(models_dir, spec[:filename])
        if File.exist?(path)
          puts "  [ok]      #{spec[:filename].ljust(32)} #{format_size(File.size(path))}  #{spec[:description]}"
        else
          puts "  [missing] #{spec[:filename].ljust(32)} #{'-'.ljust(10)}  #{spec[:description]}"
          puts "            url override: #{env_var_for(key)}"
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

    def url_for(key, spec)
      ENV[env_var_for(key)] || spec[:url]
    end

    def env_var_for(key)
      case key
      when :layout              then "RB_DOCLING_LAYOUT_URL"
      when :tableformer_encoder then "RB_DOCLING_TF_ENCODER_URL"
      when :tableformer_decoder then "RB_DOCLING_TF_DECODER_URL"
      end
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
