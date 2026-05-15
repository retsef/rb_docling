# frozen_string_literal: true

module RbDocling
  # Orchestratore: apre PDF, esegue layout + tabelle + reading order,
  # produce un DocumentTree.
  class Pipeline
    def initialize(layout: :heuristic, table: :heuristic, models_dir: nil,
                   layout_model: nil, tableformer_encoder: nil,
                   tableformer_decoder: nil)
      @layout_mode = layout
      @table_mode  = table
      @models_dir  = models_dir
      @layout_model_path = layout_model || (models_dir && File.join(models_dir, "layout.onnx"))
      @tableformer_encoder_path = tableformer_encoder || (models_dir && File.join(models_dir, "tableformer_encoder.onnx"))
      @tableformer_decoder_path = tableformer_decoder || (models_dir && File.join(models_dir, "tableformer_decoder.onnx"))

      @layout_engine = build_layout_engine
      @table_engine  = build_table_engine
    end

    def parse(pdf_path)
      nodes = []
      meta = {}

      Rpdfium.open(pdf_path) do |doc|
        meta = (doc.metadata || {}).merge(page_count: doc.page_count)
        doc.each_with_index do |page, page_idx|
          page_no = page_idx + 1

          # 1. Tabelle PRIMA (per poter escludere il loro testo dal layout)
          tables = extract_tables(page)
          table_bboxes = tables.map { |t| t[:bbox] }.compact

          # 2. Layout analysis dei blocchi non-tabella
          blocks = @layout_engine.analyze(page, page_no: page_no,
                                          exclude_bboxes: table_bboxes)

          # 3. Defense-in-depth: sottrai qualunque blocco residuo dentro tabelle
          blocks = remove_blocks_inside_tables(blocks, tables)

          # 4. Aggiungi i nodi tabella
          tables.each do |t|
            blocks << {
              type: :table,
              text: nil,
              bbox: t[:bbox],
              page_no: page_no,
              table_structure: { rows: t[:rows] }
            }
          end

          # 5. Reading order
          ordered = Layout::ReadingOrder.sort(blocks)

          # 6. Costruisci nodi
          ordered.each do |b|
            nodes << Document::Node.new(
              type: b[:type],
              text: b[:text],
              bbox: b[:bbox],
              page_no: b[:page_no],
              level: b[:level],
              font: b[:font],
              fontsize: b[:fontsize],
              weight: b[:weight],
              table_structure: b[:table_structure],
              metadata: { score: b[:score] }.compact
            )
          end
        end
      end

      Document::Tree.new(nodes: nodes, metadata: meta)
    end

    private

    def build_layout_engine
      case @layout_mode
      when :heuristic
        Layout::HeuristicLayout.new
      when :onnx
        unless @layout_model_path && File.exist?(@layout_model_path)
          warn "[Pipeline] layout ONNX richiesto ma modello assente (#{@layout_model_path}); fallback su heuristic"
          Layout::HeuristicLayout.new
        else
          Layout::OnnxLayout.new(model_path: @layout_model_path)
        end
      else
        raise Error, "layout mode non supportato: #{@layout_mode}"
      end
    end

    def build_table_engine
      case @table_mode
      when :heuristic
        Table::HeuristicTable.new
      when :onnx
        unless @tableformer_encoder_path && File.exist?(@tableformer_encoder_path)
          warn "[Pipeline] tableformer ONNX richiesto ma encoder assente; fallback su heuristic"
          Table::HeuristicTable.new
        else
          Table::OnnxTableFormer.new(
            encoder_path: @tableformer_encoder_path,
            decoder_path: (File.exist?(@tableformer_decoder_path.to_s) ? @tableformer_decoder_path : nil)
          )
        end
      else
        raise Error, "table mode non supportato: #{@table_mode}"
      end
    end

    def extract_tables(page)
      if @table_engine.is_a?(Table::OnnxTableFormer)
        # Per TableFormer serve sapere DOVE sono le tabelle: prima usiamo
        # l'heuristic per trovarle, poi TableFormer per la struttura.
        # In produzione: le bbox tabella vengono dal layout model (classe "Table").
        heuristic_tables = Table::HeuristicTable.new.extract(page)
        heuristic_tables.map { |t| @table_engine.extract(page, t[:bbox]) }
      else
        @table_engine.extract(page)
      end
    rescue StandardError => e
      warn "[Pipeline] table extraction error: #{e.message}"
      []
    end

    def remove_blocks_inside_tables(blocks, tables)
      blocks.reject do |b|
        next false unless b[:bbox]
        tables.any? { |t| t[:bbox] && t[:bbox].contains?(b[:bbox], tol: 2.0) }
      end
    end
  end
end
