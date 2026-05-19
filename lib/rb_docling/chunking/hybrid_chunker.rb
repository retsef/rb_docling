# frozen_string_literal: true

module RbDocling
  module Chunking
    # Chunker ispirato a HybridChunker di Docling, con due modalità di raggruppamento.
    #
    # ## Modalità
    #
    # **`mode: :element`** (default, comportamento storico)
    #
    # Ogni nodo semantico del tree → un chunk separato. Granularità fine,
    # ottima per precision sul retrieval.
    #
    # **`mode: :section`**
    #
    # Una `section_header` (o `title`) e tutto il suo contenuto fino al
    # prossimo header dello stesso livello o superiore → un solo chunk.
    # Ottima per chunk auto-contenuti, dove l'LLM riceve heading + paragrafi
    # + tabelle insieme. Più RAG-friendly per query "concettuali".
    #
    # ## Contextualize
    #
    # Quando `contextualize: true` (default), il `:text` del chunk viene
    # automaticamente preceduto dal heading path serializzato. Esempio:
    #
    #   Capitolo 2: Configurazione
    #   2.1 Parametri principali
    #
    #   La configurazione si effettua via file YAML...
    #
    # È l'equivalente di `chunker.contextualize(chunk)` in Docling, ma
    # applicato in-place al testo del chunk così che l'embedding model
    # riceva il contesto senza che il consumer debba ricostruirlo.
    #
    # Se preferisci il testo "raw" (per displaying all'utente), il chunk
    # mantiene `metadata[:headings]` e `metadata[:heading_id]` per ricostruire
    # il prefisso a piacere.
    class HybridChunker
      DEFAULT_MAX_TOKENS = 512
      DEFAULT_MIN_TOKENS = 64

      VALID_MODES = %i[element section].freeze

      attr_reader :max_tokens, :min_tokens, :mode, :contextualize

      def initialize(max_tokens: DEFAULT_MAX_TOKENS,
                     min_tokens: DEFAULT_MIN_TOKENS,
                     mode: :element,
                     contextualize: true,
                     tokenizer: nil)
        unless VALID_MODES.include?(mode)
          raise ArgumentError, "mode deve essere uno di #{VALID_MODES.inspect}, ricevuto #{mode.inspect}"
        end
        @max_tokens = max_tokens
        @min_tokens = min_tokens
        @mode = mode
        @contextualize = contextualize
        @tokenizer = tokenizer || method(:approx_tokenize)
      end

      def chunk(tree)
        raw_chunks = case @mode
                     when :element then build_element_chunks(tree)
                     when :section then build_section_chunks(tree)
                     end

        split_chunks = raw_chunks.flat_map { |c| split_if_needed(c) }
        merged = merge_small_adjacent(split_chunks)
        merged.each { |c| apply_contextualization(c) } if @contextualize
        merged
      end

      private

        # ============================================================
        # MODE :element — ogni nodo è un chunk
        # ============================================================

        def build_element_chunks(tree)
          chunks = []
          tree.nodes.each_with_index do |node, idx|
            next if skip_for_chunking?(node)
            headings_path = tree.headings_path_for(idx)
            serialized = serialize_node(node)
            next if serialized.empty?
            chunks << build_chunk(serialized, headings_path,
                                  primary_node: node,
                                  source_indices: [idx])
          end
          chunks
        end

        def skip_for_chunking?(node)
          node.heading? && (node.text.nil? || node.text.strip.empty?)
        end

        # ============================================================
        # MODE :section — heading + tutto il suo contenuto fino al prossimo
        #                 header dello stesso livello o superiore
        # ============================================================

        def build_section_chunks(tree)
          boundaries = compute_section_boundaries(tree.nodes)
          chunks = []
          boundaries.each do |start_idx, end_idx|
            slice = tree.nodes[start_idx...end_idx]
            headings_path = tree.headings_path_for(start_idx)
            body = serialize_section_body(slice)
            next if body.empty?
            chunks << build_chunk(body, headings_path,
                                  primary_node: slice.first,
                                  source_indices: (start_idx...end_idx).to_a,
                                  section: true)
          end
          chunks
        end

        # Per ogni heading/title, calcola l'intervallo [start, end) di nodi
        # che compongono la sezione.
        def compute_section_boundaries(nodes)
          n = nodes.size
          return [] if n.zero?

          boundaries = []
          first_heading = nodes.index(&:heading?)

          if first_heading.nil?
            return [[0, n]]
          end

          # Sezione "preamble": nodi prima del primo heading (es. abstract/intro)
          boundaries << [0, first_heading] if first_heading > 0

          i = first_heading
          while i < n
            unless nodes[i].heading?
              i += 1
              next
            end
            current_level = nodes[i].level || 1
            end_idx = n
            ((i + 1)...n).each do |j|
              next unless nodes[j].heading?
              other_level = nodes[j].level || 1
              if other_level <= current_level
                end_idx = j
                break
              end
            end
            boundaries << [i, end_idx]
            i = end_idx
          end
          boundaries
        end

        # Serializza il corpo di una sezione. L'heading di apertura NON viene
        # incluso nel body: arriverà via contextualize (o noi lo prependiamo
        # esplicitamente se contextualize=false).
        def serialize_section_body(slice)
          first_is_heading = slice.first&.heading?
          opening_heading = first_is_heading ? slice.first.text.to_s.strip : nil

          parts = []
          slice.each_with_index do |node, i|
            # Salta l'heading di apertura
            next if i.zero? && first_is_heading
            s = serialize_node(node)
            parts << s unless s.nil? || s.empty?
          end
          body = parts.join("\n\n")

          # Se contextualize=false, devo comunque mantenere visibile l'heading.
          if !@contextualize && opening_heading && !opening_heading.empty?
            body = body.empty? ? opening_heading : "#{opening_heading}\n\n#{body}"
          end
          body
        end

        # ============================================================
        # Serializzazione per tipo
        # ============================================================

        def serialize_node(node)
          case node.type
          when :title, :section_header
            node.text.to_s
          when :table
            serialize_table(node)
          when :list_item
            clean = node.text.to_s.sub(/\A\s*[•·▪\-\*]\s*/, "")
            "- #{clean}"
          when :picture
            node.metadata[:caption] ? "[Figure: #{node.metadata[:caption]}]" : ""
          when :page_header, :page_footer
            ""
          else
            node.text.to_s
          end
        end

        def serialize_table(node)
          return "" unless node.table_structure
          rows = node.table_structure[:rows] || []
          return "" if rows.empty?
          head = rows.first
          body = rows[1..] || []
          lines = []
          lines << "| #{head.map(&:to_s).join(' | ')} |"
          lines << "| #{head.map { '---' }.join(' | ')} |"
          body.each { |r| lines << "| #{r.map(&:to_s).join(' | ')} |" }
          lines.join("\n")
        end

        # ============================================================
        # Build chunk + refinement
        # ============================================================

        def build_chunk(text, headings_path, primary_node:, source_indices:, section: false)
          headings = headings_path.map { |h| { level: h.level, text: h.text } }
          {
            text: text,
            token_count: @tokenizer.call(text),
            metadata: {
              type: section ? :section : primary_node.type,
              page_no: primary_node.page_no,
              bbox: primary_node.bbox&.to_a,
              headings: headings,
              heading_id: headings.map { |h| h[:text] }.join(" > "),
              source_indices: source_indices
            }
          }
        end

        def apply_contextualization(chunk)
          headings = chunk[:metadata][:headings] || []
          return if headings.empty?

          # Se il chunk inizia già con l'ultimo heading del path, non lo
          # duplichiamo: il prefisso è il path *fino a* quel nodo escluso.
          # Caso tipico: mode :element su un nodo heading. Il chunk text è
          # "1.1 Requisiti" e l'ultimo del headings_path è anche
          # "1.1 Requisiti".
          last_heading_text = headings.last[:text].to_s.strip
          chunk_first_line = chunk[:text].lines.first.to_s.strip
          prefix_headings = if chunk_first_line == last_heading_text
                              headings[0...-1]
                            else
                              headings
                            end
          return if prefix_headings.empty?

          prefix = prefix_headings.map { |h| h[:text] }.join("\n")
          chunk[:text] = "#{prefix}\n\n#{chunk[:text]}"
          chunk[:token_count] = @tokenizer.call(chunk[:text])
          chunk[:metadata][:contextualized] = true
        end

        def split_if_needed(chunk)
          return [chunk] if chunk[:token_count] <= @max_tokens
          sentences = split_sentences(chunk[:text])
          sub_chunks = []
          buf = []
          buf_tokens = 0
          sentences.each do |s|
            s_tokens = @tokenizer.call(s)
            if buf_tokens + s_tokens > @max_tokens && !buf.empty?
              sub_chunks << make_sub(chunk, buf.join(" "), buf_tokens)
              buf = [s]
              buf_tokens = s_tokens
            else
              buf << s
              buf_tokens += s_tokens
            end
          end
          sub_chunks << make_sub(chunk, buf.join(" "), buf_tokens) unless buf.empty?
          sub_chunks
        end

        def make_sub(parent, text, tokens)
          {
            text: text,
            token_count: tokens,
            metadata: parent[:metadata].merge(split: true)
          }
        end

        def split_sentences(text)
          parts = text.scan(/[^.!?]+[.!?]+|\S[^.!?]*\z/).map(&:strip).reject(&:empty?)
          return parts if parts.size > 1
          return parts if text.length < 80
          words = text.split(/\s+/)
          chunks = []
          buf = []
          len = 0
          words.each do |w|
            if len + w.length > 80 && !buf.empty?
              chunks << buf.join(" ")
              buf = [w]
              len = w.length
            else
              buf << w
              len += w.length + 1
            end
          end
          chunks << buf.join(" ") unless buf.empty?
          chunks
        end

        def merge_small_adjacent(chunks)
          merged = []
          i = 0
          while i < chunks.size
            c = chunks[i]
            while i + 1 < chunks.size &&
                  same_heading?(c, chunks[i + 1]) &&
                  c[:token_count] + chunks[i + 1][:token_count] <= @max_tokens &&
                  (c[:token_count] < @min_tokens || chunks[i + 1][:token_count] < @min_tokens)
              nxt = chunks[i + 1]
              c = {
                text: "#{c[:text]}\n\n#{nxt[:text]}",
                token_count: c[:token_count] + nxt[:token_count],
                metadata: c[:metadata].merge(merged: true)
              }
              i += 1
            end
            merged << c
            i += 1
          end
          merged
        end

        def same_heading?(a, b)
          a[:metadata][:heading_id] == b[:metadata][:heading_id]
        end

        def approx_tokenize(text)
          return 0 if text.nil?
          (text.length / 4.0).ceil
        end
    end
  end
end
