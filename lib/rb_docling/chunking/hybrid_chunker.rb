# frozen_string_literal: true

module RbDocling
  module Chunking
    # Chunker ispirato a HybridChunker di Docling.
    #
    # Strategia:
    #   1. Document-based: ogni nodo del tree è un candidato chunk, con metadata
    #      delle heading antenate (heading path).
    #   2. Token-aware refinement:
    #      a) Splitting: se un chunk supera max_tokens, lo spezza su confini di
    #         frase, mantenendo l'heading path.
    #      b) Merging: chunk adiacenti sotto la stessa heading e sotto il limite
    #         vengono fusi se la loro somma resta sotto max_tokens.
    #
    # Tokenizer: per semplicità usa un'approssimazione tipo cl100k (~4 char/token).
    # In produzione passa un tokenizer reale (es. wrapper su tiktoken via bindings).
    class HybridChunker
      DEFAULT_MAX_TOKENS = 512
      DEFAULT_MIN_TOKENS = 64

      attr_reader :max_tokens, :min_tokens

      def initialize(max_tokens: DEFAULT_MAX_TOKENS, min_tokens: DEFAULT_MIN_TOKENS,
                     tokenizer: nil)
        @max_tokens = max_tokens
        @min_tokens = min_tokens
        @tokenizer = tokenizer || method(:approx_tokenize)
      end

      def chunk(tree)
        # Fase 1: chunk strutturali con heading path
        raw_chunks = []
        tree.nodes.each_with_index do |node, idx|
          next if skip_for_chunking?(node)
          headings_path = tree.headings_path_for(idx)
          serialized = serialize_node(node)
          next if serialized.empty?
          raw_chunks << build_chunk(node, serialized, headings_path)
        end

        # Fase 2a: splitting di chunk troppo grossi
        split_chunks = raw_chunks.flat_map { |c| split_if_needed(c) }

        # Fase 2b: merging di chunk adiacenti piccoli sotto la stessa heading
        merge_small_adjacent(split_chunks)
      end

      private

      def skip_for_chunking?(node)
        # Le heading da sole non sono chunk: viaggiano come metadata
        # nei chunk dei loro figli.
        node.heading? && (node.text.nil? || node.text.strip.empty?)
      end

      def serialize_node(node)
        case node.type
        when :title, :section_header
          node.text.to_s
        when :table
          serialize_table(node)
        when :list_item
          "- #{node.text}"
        when :picture
          node.metadata[:caption] ? "[Figure: #{node.metadata[:caption]}]" : ""
        else
          node.text.to_s
        end
      end

      def serialize_table(node)
        return "" unless node.table_structure
        rows = node.table_structure[:rows] || []
        return "" if rows.empty?
        # Stile markdown: header + separator + righe
        head = rows.first
        body = rows[1..] || []
        lines = []
        lines << "| #{head.map(&:to_s).join(' | ')} |"
        lines << "| #{head.map { '---' }.join(' | ')} |"
        body.each { |r| lines << "| #{r.map(&:to_s).join(' | ')} |" }
        lines.join("\n")
      end

      def build_chunk(node, text, headings_path)
        headings = headings_path.map { |h| { level: h.level, text: h.text } }
        {
          text: text,
          token_count: @tokenizer.call(text),
          metadata: {
            type: node.type,
            page_no: node.page_no,
            bbox: node.bbox&.to_a,
            headings: headings,
            heading_id: headings.map { |h| h[:text] }.join(" > ")
          }
        }
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
        # Tenta lo split su punteggiatura
        parts = text.scan(/[^.!?]+[.!?]+|\S[^.!?]*\z/).map(&:strip).reject(&:empty?)
        return parts if parts.size > 1
        # Fallback: testi privi di punteggiatura - split su gruppi di parole
        # di ~80 caratteri (preservando word boundary).
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
          # Tenta di mergiare con i successivi finché stessa heading e sotto limite
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

      # Approssimazione: 1 token ≈ 4 caratteri (regola pollice GPT/Claude).
      def approx_tokenize(text)
        return 0 if text.nil?
        (text.length / 4.0).ceil
      end
    end
  end
end
