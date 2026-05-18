# frozen_string_literal: true

module RbDocling
  module Document
    # Albero del documento: una lista ordinata di nodi top-level (in reading
    # order) con una gerarchia implicita data dalle heading. Mantiene metadata
    # del PDF originale.
    class Tree
      attr_reader :nodes, :metadata

      def initialize(nodes: [], metadata: {})
        @nodes = nodes
        @metadata = metadata
      end

      def each(&block); @nodes.each(&block); end

      # Esporta in Markdown.
      #
      # Opzioni:
      #   strict_text: true        → rimuove tutto il markup, ritorna plain text
      #   include_furniture: false → omette page_header/page_footer (default)
      #   associate_captions: true → fonde caption con picture/table adiacente
      def to_md(strict_text: false, include_furniture: false, associate_captions: true)
        nodes = @nodes
        nodes = nodes.reject { |n| %i[page_header page_footer].include?(n.type) } unless include_furniture
        nodes = associate_captions(nodes) if associate_captions

        lines ||= nodes.map { it.text.to_s } if strict_text
        lines ||= nodes.map(&:to_md)
        lines.reject { |l| l.nil? || l.empty? }.join("\n\n")
      end

      def to_h
        { metadata: @metadata, nodes: @nodes.map(&:to_h) }
      end

      # Restituisce, per ogni nodo, la sequenza di heading antenati
      # (utile al chunker per il contesto).
      def headings_path_for(node_index)
        path = []
        current_levels = {}
        @nodes[0..node_index].each_with_index do |n, _|
          next unless n.heading?
          lv = n.level || 1
          current_levels[lv] = n
          current_levels.delete_if { |k, _| k > lv }
        end
        current_levels.keys.sort.each { |k| path << current_levels[k] }
        path
      end

      private

      # Associa caption alla picture/table vicina (precedente o successiva,
      # entro 60 pt di distanza verticale sulla stessa pagina). La caption
      # viene fusa nel metadata :caption del nodo target e rimossa.
      def associate_captions(nodes)
        result = []
        skip_idx = nil
        nodes.each_with_index do |n, i|
          next if skip_idx == i
          if n.type == :caption
            target = find_caption_target(nodes, i)
            if target
              target.metadata = target.metadata.merge(caption: n.text)
              next # la caption viene assorbita
            end
          end
          result << n
        end
        result
      end

      def find_caption_target(nodes, idx)
        cap = nodes[idx]
        return nil unless cap.bbox && cap.page_no
        candidates = []
        # Cerca picture/table vicini sopra/sotto
        [-1, 1, -2, 2].each do |offset|
          target = nodes[idx + offset]
          next unless target
          next unless %i[picture table].include?(target.type)
          next unless target.page_no == cap.page_no
          next unless target.bbox
          # Distanza verticale tra centri delle bbox
          dist = (target.bbox.cy - cap.bbox.cy).abs
          candidates << [dist, target] if dist < 60
        end
        candidates.min_by(&:first)&.last
      end
    end
  end
end
