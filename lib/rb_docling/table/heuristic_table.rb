# frozen_string_literal: true

module RbDocling
  module Table
    # Wrapper sopra Rpdfium::Table::Extractor. È l'opzione "no-ML".
    # Buona su tabelle con bordi visibili. Limitata su tabelle borderless
    # (per quelle serve TableFormer ONNX).
    class HeuristicTable
      # Soglie per riconoscere e scartare falsi positivi.
      # Una "tabella" che ha solo 1 colonna è quasi sempre un blocco di testo
      # interpretato male.
      MIN_COLS = 2
      # Almeno questa frazione di celle dev'essere non-vuota
      MIN_NON_EMPTY_RATIO = 0.4
      # Almeno questo numero di righe (sotto è ambiguo, spesso falso positivo)
      MIN_ROWS = 2

      def initialize(strategy: :lines, **opts)
        @strategy = strategy
        @opts = opts
      end

      # Estrae tabelle da una pagina rpdfium.
      # Restituisce Array<{ bbox:, rows: [[str,...], ...] }>.
      def extract(page)
        extractor = Rpdfium::Table::Extractor.new(
          page,
          vertical_strategy:   @strategy,
          horizontal_strategy: @strategy,
          **@opts
        )
        candidates = extractor.tables.map do |t|
          bbox_arr = t.bbox
          rows = t.extract.map { |row| row.map { |c| c.to_s.strip } }
          # Rimuovi righe interamente vuote
          rows = rows.reject { |r| r.all?(&:empty?) }
          {
            bbox: Document::BBox.from_a(bbox_arr),
            rows: rows
          }
        end
        candidates.select { |t| valid_table?(t) }
      rescue StandardError => e
        warn "[HeuristicTable] errore: #{e.message}"
        []
      end

      private

      def valid_table?(t)
        rows = t[:rows]
        return false if rows.size < MIN_ROWS
        max_cols = rows.map(&:size).max || 0
        return false if max_cols < MIN_COLS
        # Tutte le righe hanno lo stesso numero di colonne (consistenza)
        consistent = rows.all? { |r| r.size == max_cols }
        return false unless consistent
        total = rows.flatten.size
        non_empty = rows.flatten.count { |c| !c.empty? }
        ratio = total.zero? ? 0.0 : non_empty.to_f / total
        return false if ratio < MIN_NON_EMPTY_RATIO
        true
      end
    end
  end
end
