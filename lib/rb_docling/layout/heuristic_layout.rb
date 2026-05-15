# frozen_string_literal: true

module RbDocling
  module Layout
    # Layout analysis basato su euristiche: usa font-size, weight, posizione
    # per inferire ruolo (heading vs body) senza modelli ML.
    #
    # Limiti noti:
    #   - non funziona su layout multi-colonna (richiede clustering colonne)
    #   - non distingue caption da text
    #   - non identifica figure
    # Ma per documenti single-column ben formattati è sorprendentemente robusto.
    class HeuristicLayout
      # Soglia rispetto alla mediana per considerare un testo come heading.
      HEADING_FONT_RATIO = 1.15

      def initialize(median_factor: HEADING_FONT_RATIO)
        @median_factor = median_factor
      end

      # Riceve la pagina rpdfium, restituisce un Array<Hash> con elementi
      # tipo: [{ type:, text:, bbox:, font:, fontsize:, weight:, page_no: }]
      #
      # exclude_bboxes: lista di Document::BBox da escludere (tipicamente le
      # tabelle già identificate, per evitare che il loro testo venga
      # interpretato come paragrafi).
      def analyze(page, page_no:, exclude_bboxes: [])
        words = page.words
        return [] if words.empty?

        unless exclude_bboxes.empty?
          words = words.reject { |w| inside_any?(w, exclude_bboxes) }
          return [] if words.empty?
        end

        # Calcolo statistiche font
        font_sizes = words.map { |w| w[:fontsize] || 0.0 }.reject(&:zero?)
        median = median_of(font_sizes)
        body_size = median # baseline body

        # Raggruppo word in linee (stesso baseline)
        lines = group_into_lines(words)

        # Raggruppo linee in blocchi (interruzioni su font-size change o gap)
        blocks = group_into_blocks(lines, body_size: body_size)

        # Classifico ogni blocco e spezzo eventuali bullet inline
        blocks.flat_map do |b|
          classified = classify_block(b, body_size: body_size, page_no: page_no)
          split_inline_bullets(classified)
        end
      end

      private

      def inside_any?(word, bboxes)
        # Word con sample point al centro
        wcx = (word[:x0] + word[:x1]) / 2.0
        wcy = (word[:top] + word[:bottom]) / 2.0
        bboxes.any? do |bb|
          wcx >= bb.x0 && wcx <= bb.x1 && wcy >= bb.top && wcy <= bb.bottom
        end
      end

      def median_of(arr)
        return 0.0 if arr.empty?
        sorted = arr.sort
        n = sorted.size
        n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
      end

      def group_into_lines(words, y_tol: 2.5)
        sorted = words.sort_by { |w| [w[:top], w[:x0]] }
        lines = []
        current = []
        current_top = nil
        sorted.each do |w|
          if current_top.nil? || (w[:top] - current_top).abs <= y_tol
            current << w
            current_top ||= w[:top]
          else
            lines << current
            current = [w]
            current_top = w[:top]
          end
        end
        lines << current unless current.empty?
        lines.map { |ws| line_from_words(ws) }
      end

      def line_from_words(ws)
        ws_sorted = ws.sort_by { |w| w[:x0] }
        {
          text: ws_sorted.map { |w| w[:text] }.join(" "),
          x0: ws_sorted.map { |w| w[:x0] }.min,
          x1: ws_sorted.map { |w| w[:x1] }.max,
          top: ws_sorted.map { |w| w[:top] }.min,
          bottom: ws_sorted.map { |w| w[:bottom] }.max,
          fontsize: dominant(ws_sorted.map { |w| w[:fontsize] }),
          font: dominant(ws_sorted.map { |w| w[:font] }),
          weight: dominant(ws_sorted.map { |w| w[:weight] })
        }
      end

      def dominant(arr)
        return nil if arr.compact.empty?
        arr.compact.group_by(&:itself).max_by { |_, v| v.size }.first
      end

      def group_into_blocks(lines, body_size:)
        return [] if lines.empty?
        blocks = []
        current = [lines.first]
        lines.each_cons(2) do |a, b|
          gap = b[:top] - a[:bottom]
          line_h = a[:bottom] - a[:top]
          # Cambio di font size > 1 punto: indica passaggio heading/body o tra
          # heading di livelli diversi. Sufficiente da solo a spezzare il blocco.
          font_changed = (b[:fontsize] - a[:fontsize]).abs > 1.0
          # Cambio bold/non-bold
          a_bold = a[:font].to_s.match?(/Bold|Black|Heavy/i)
          b_bold = b[:font].to_s.match?(/Bold|Black|Heavy/i)
          weight_changed = a_bold != b_bold
          # Gap superiore a 1.2 line-height
          gap_break = gap > line_h * 1.2

          if font_changed || weight_changed || gap_break
            blocks << current
            current = [b]
          else
            current << b
          end
        end
        blocks << current unless current.empty?
        blocks.map { |ls| block_from_lines(ls) }
      end

      def block_from_lines(lines)
        {
          text: lines.map { |l| l[:text] }.join(" "),
          x0: lines.map { |l| l[:x0] }.min,
          x1: lines.map { |l| l[:x1] }.max,
          top: lines.map { |l| l[:top] }.min,
          bottom: lines.map { |l| l[:bottom] }.max,
          fontsize: lines.first[:fontsize],
          font: lines.first[:font],
          weight: lines.first[:weight],
          n_lines: lines.size
        }
      end

      def classify_block(b, body_size:, page_no:)
        text = b[:text].to_s.strip
        fs = b[:fontsize] || body_size
        ratio = body_size.zero? ? 1.0 : (fs / body_size)
        font_str = b[:font].to_s
        bold = font_str.match?(/Bold|Black|Heavy/i)

        type, level = if ratio >= 1.6
                        [:title, 1]
                      elsif ratio >= 1.35 || (ratio >= 1.15 && bold)
                        [:section_header, level_from_ratio(ratio)]
                      elsif b[:n_lines] == 1 && bold && b[:text].length < 80
                        [:section_header, level_from_ratio(ratio)]
                      else
                        [:text, nil]
                      end

        # bullet/list-item detection semplice all'inizio del blocco
        if type == :text && text.match?(/\A\s*([\-•·▪]|\d+[.)])\s/)
          type = :list_item
        end

        {
          type: type,
          text: text,
          bbox: Document::BBox.new(x0: b[:x0], top: b[:top], x1: b[:x1], bottom: b[:bottom]),
          font: b[:font],
          fontsize: fs,
          weight: b[:weight],
          level: level,
          page_no: page_no
        }
      end

      # Spezza un blocco di testo che contiene bullet inline in più nodi.
      # Es. "Lista: • a • b • c" → ["Lista:", "• a", "• b", "• c"].
      # Riceve un Hash blocco classificato e ne restituisce 1+ (gli altri
      # ereditano bbox/font dal padre per semplicità).
      def split_inline_bullets(block)
        text = block[:text]
        # Cerca bullet character preceduti da spazio
        return [block] unless text.match?(/\s[•·▪]\s/)
        parts = text.split(/\s+(?=[•·▪]\s)/).map(&:strip).reject(&:empty?)
        return [block] if parts.size <= 1
        parts.map.with_index do |part, i|
          {
            type: part.match?(/\A[•·▪]/) ? :list_item : block[:type],
            text: part,
            bbox: block[:bbox],
            font: block[:font],
            fontsize: block[:fontsize],
            weight: block[:weight],
            level: block[:level],
            page_no: block[:page_no],
            metadata: { split_inline: i > 0 }
          }
        end
      end

      def level_from_ratio(ratio)
        case ratio
        when 1.6..Float::INFINITY then 1
        when 1.35..1.6 then 2
        when 1.15..1.35 then 3
        else 4
        end
      end
    end
  end
end
