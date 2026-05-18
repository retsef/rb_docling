# frozen_string_literal: true

module RbDocling
  module Document
    # Un nodo del DocumentTree. Tipi corrispondono alle etichette DocLayNet
    # più qualche tipo composto:
    #   :title, :section_header, :text, :list_item, :caption, :footnote,
    #   :page_header, :page_footer, :table, :picture, :formula
    # I nodi tabella hanno l'attributo `:table_structure` con righe/celle.
    class Node
      VALID_TYPES = %i[
        title section_header text list_item caption footnote
        page_header page_footer table picture formula list
      ].freeze

      attr_accessor :type, :text, :bbox, :page_no, :level,
                    :font, :fontsize, :weight,
                    :table_structure, :children, :metadata

      def initialize(type:, text: nil, bbox: nil, page_no: nil, level: nil,
                     font: nil, fontsize: nil, weight: nil,
                     table_structure: nil, children: [], metadata: {})
        raise ArgumentError, "type invalido: #{type}" unless VALID_TYPES.include?(type)

        @type = type
        @text = text
        @bbox = bbox
        @page_no = page_no
        @level = level # per heading: 1..N
        @font = font
        @fontsize = fontsize
        @weight = weight
        @table_structure = table_structure
        @children = children
        @metadata = metadata
      end

      def heading?
        %i[title section_header].include?(@type)
      end

      def to_h
        {
          type: @type,
          text: @text,
          bbox: @bbox&.to_a,
          page_no: @page_no,
          level: @level,
          font: @font,
          fontsize: @fontsize,
          table_structure: @table_structure,
          metadata: @metadata
        }
      end

      # Markdown leggibile per debugging
      def to_md
        case @type
        when :title then "# #{@text}"
        when :section_header then ("#" * ([(@level || 2) + 1, 6].min)) + " #{@text}"
        when :list_item then render_list_item_md
        when :caption then "_#{@text}_"
        when :table then render_table_md
        when :picture then render_picture_md
        else
          @text.to_s
        end
      end

      private

      def render_table_md
        return "" unless @table_structure && @table_structure[:rows]

        rows = @table_structure[:rows]
        return "" if rows.empty?

        head = rows.first
        body = rows[1..] || []

        lines = []
        lines << "| #{head.map(&:to_s).join(' | ')} |"
        lines << "| #{head.map { '---' }.join(' | ')} |"

        body.each { |r| lines << "| #{r.map(&:to_s).join(' | ')} |" }

        lines.join("\n")
      end

      def render_picture_md
        alt = @metadata[:caption] || "image"
        img = @metadata[:image_path] || @metadata[:image_uri] || "#"

        return "![#{alt}](#{img})\n\n_#{@metadata[:caption]}_" if @metadata[:caption]

        "![#{alt}](#{img})"
      end

      def render_list_item_md
        # Rimuovi bullet duplicato in testa (•, ·, ▪, -, *) se presente
        clean = @text.to_s.sub(/\A\s*[•·▪\-\*]\s*/, "")
        indent = "  " * ((@metadata[:list_level] || 1) - 1)
        "#{indent}- #{clean}"
      end
    end
  end
end
