# frozen_string_literal: true

module RbDocling
  module Table
    # TableFormer ONNX: data l'immagine ritagliata di una tabella, ricostruisce
    # la struttura della tabella (matrice di celle) e i bbox di ogni cella.
    #
    # Architettura del modello (da paper IBM CVPR 2022 + OTSL paper):
    #   - CNN backbone (ResNet-18) → features
    #   - Transformer encoder → encoder_features
    #   - Structure Decoder (autoregressivo) → sequenza di token OTSL
    #   - Cell BBox Decoder → bbox per ogni cella token
    #
    # Vocabolario OTSL (Optimized Table Structure Language):
    #   - "fcel": cella vuota / nuovo contenuto
    #   - "ecel": cella di completamento vuota
    #   - "lcel": cella estesa a sinistra (colspan)
    #   - "ucel": cella estesa sopra (rowspan)
    #   - "xcel": cella estesa diagonalmente
    #   - "nl":   nuova riga
    #   - "<start>", "<end>", "<pad>"
    #
    # IMPORTANTE: l'esatto layout I/O del file .onnx Docling TableFormer
    # varia tra le versioni di esportazione. Questo modulo è strutturato per
    # essere adattato:
    #   - se l'export espone encoder+decoder come un singolo grafo monolitico
    #     che fa il loop internamente (raro), usa run_monolithic
    #   - se espone encoder e decoder separati (formato preferito per il
    #     decoding autoregressivo efficiente), usa run_split (default).
    #
    # Per i pesi `ds4sd-docling-models-onnx` (versione JPQD quantizzata),
    # consulta example.py della repo HF per shape input esatte.
    class OnnxTableFormer
      DEFAULT_INPUT_SIZE = 448 # comune per TableFormer (può essere 224/448)
      DEFAULT_MAX_STEPS  = 1024

      # Vocabolario OTSL (placeholder; sostituire con quello reale del modello).
      OTSL_TOKENS = %w[<pad> <start> <end> fcel ecel lcel ucel xcel nl].freeze

      def initialize(encoder_path:, decoder_path: nil,
                     input_size: DEFAULT_INPUT_SIZE,
                     max_steps: DEFAULT_MAX_STEPS,
                     vocab: OTSL_TOKENS,
                     mode: :auto)
        @encoder_path = encoder_path
        @decoder_path = decoder_path
        @input_size   = input_size
        @max_steps    = max_steps
        @vocab        = vocab
        @mode         = detect_mode(mode)
        @encoder = Models::Loader.session(encoder_path)
        @decoder = Models::Loader.session(decoder_path) if @decoder_path
      end

      # Riceve:
      #   page: rpdfium page
      #   bbox: Document::BBox della tabella sulla pagina (coord PDF)
      # Restituisce: { bbox: bbox, rows: [[cell_text,...], ...] }
      def extract(page, bbox)
        # 1. Render della regione tabella come immagine
        img_w, img_h, rgb = render_table_region(page, bbox)
        tensor, _pad = preprocess(rgb, img_w, img_h)

        # 2. Encoder forward
        enc_out = run_encoder(tensor)

        # 3. Decoding autoregressivo della struttura OTSL
        token_ids, cell_bboxes = decode_structure(enc_out)

        # 4. Conversione OTSL -> matrice di celle con bbox
        cell_grid = otsl_to_grid(token_ids, cell_bboxes)

        # 5. Per ogni cella, estrai il testo da rpdfium nella bbox di cella
        #    (mappata in coord PDF)
        rows = cell_grid.map do |row|
          row.map do |cell|
            next "" if cell.nil?
            cell_pdf_bbox = map_cell_to_pdf(cell[:bbox], bbox, img_w, img_h)
            text_in_bbox(page, cell_pdf_bbox)
          end
        end

        { bbox: bbox, rows: rows }
      end

      private

      def detect_mode(requested)
        return requested unless requested == :auto
        @decoder_path ? :split : :monolithic
      end

      def render_table_region(page, bbox)
        # Render dell'intera pagina, poi crop. Più semplice e robusto.
        scale = @input_size.to_f / [bbox.width, bbox.height].max
        w, h, bytes, _stride = page.render(scale: scale, output: :rgba)

        # Calcolo coordinate di crop in pixel di rendering
        px_per_pt_x = w.to_f / page.width
        px_per_pt_y = h.to_f / page.height
        crop_x0 = (bbox.x0 * px_per_pt_x).round.clamp(0, w - 1)
        crop_y0 = (bbox.top * px_per_pt_y).round.clamp(0, h - 1)
        crop_x1 = (bbox.x1 * px_per_pt_x).round.clamp(crop_x0 + 1, w)
        crop_y1 = (bbox.bottom * px_per_pt_y).round.clamp(crop_y0 + 1, h)
        cw = crop_x1 - crop_x0
        ch = crop_y1 - crop_y0

        # Crop RGBA -> RGB
        rgb = String.new(capacity: cw * ch * 3)
        ch.times do |y|
          src_row = (crop_y0 + y) * w * 4 + crop_x0 * 4
          cw.times do |x|
            i = src_row + x * 4
            rgb << bytes.getbyte(i).chr
            rgb << bytes.getbyte(i + 1).chr
            rgb << bytes.getbyte(i + 2).chr
          end
        end
        [cw, ch, rgb]
      end

      MEAN = [0.485, 0.456, 0.406].freeze
      STD  = [0.229, 0.224, 0.225].freeze

      def preprocess(rgb_bytes, w, h)
        size = @input_size
        # Resize semplice (nearest) a size x size
        x_ratio = w.to_f / size
        y_ratio = h.to_f / size
        r_ch = Array.new(size * size, 0.0)
        g_ch = Array.new(size * size, 0.0)
        b_ch = Array.new(size * size, 0.0)
        size.times do |y|
          sy = (y * y_ratio).to_i.clamp(0, h - 1)
          size.times do |x|
            sx = (x * x_ratio).to_i.clamp(0, w - 1)
            si = (sy * w + sx) * 3
            di = y * size + x
            r = rgb_bytes.getbyte(si)     / 255.0
            g = rgb_bytes.getbyte(si + 1) / 255.0
            b = rgb_bytes.getbyte(si + 2) / 255.0
            r_ch[di] = (r - MEAN[0]) / STD[0]
            g_ch[di] = (g - MEAN[1]) / STD[1]
            b_ch[di] = (b - MEAN[2]) / STD[2]
          end
        end
        tensor = [[r_ch.each_slice(size).to_a,
                   g_ch.each_slice(size).to_a,
                   b_ch.each_slice(size).to_a]]
        [tensor, {}]
      end

      def run_encoder(tensor)
        inp = @encoder.inputs.first[:name]
        out = @encoder.run(nil, { inp => tensor })
        # ritorno la lista completa di output (encoder_features, eventuale mask, ...)
        # da decidere in base al modello specifico
        out
      end

      # Loop di decoding autoregressivo greedy.
      #
      # NOTA: questa è la struttura *generica* del decoding per modelli
      # transformer encoder-decoder. La forma esatta degli input/output del
      # decoder ONNX di TableFormer (KV cache, attention mask, posizioni)
      # dipende dall'esportazione: alcune versioni nascondono il loop dentro
      # un singolo Run con tag dinamici, altre lo espongono. Lasciamo qui un
      # contratto chiaro con hook da implementare quando si conosce il file
      # .onnx specifico.
      def decode_structure(enc_out)
        if @mode == :monolithic
          # In monolithic mode l'encoder è già il modello completo: i suoi
          # output sono già la sequenza di token + bbox.
          extract_tokens_and_boxes(enc_out)
        else
          # Decoding step-by-step
          start_id = @vocab.index("<start>") || 1
          end_id   = @vocab.index("<end>")   || 2
          tokens = [start_id]
          cell_boxes = []

          dec_input_name  = @decoder.inputs.find { |i| i[:name].match?(/dec|token|input_ids/i) }&.dig(:name) || @decoder.inputs.first[:name]
          enc_feat_name   = @decoder.inputs.find { |i| i[:name].match?(/enc|memory|features/i) }&.dig(:name)
          # encoder output assumiamo sia il primo
          enc_features = enc_out.first

          @max_steps.times do
            feeds = { dec_input_name => [tokens] }
            feeds[enc_feat_name] = enc_features if enc_feat_name
            res = @decoder.run(nil, feeds)
            logits = res.first.last
            next_id = greedy_argmax(logits)
            tokens << next_id
            cell_boxes << res[1].last if res[1]
            break if next_id == end_id
          end
          [tokens, cell_boxes]
        end
      rescue StandardError => e
        warn "[OnnxTableFormer] decode error: #{e.message}"
        [[], []]
      end

      def extract_tokens_and_boxes(out)
        # Per modelli monolithic: cerchiamo per nome o per shape
        tokens = out.first
        boxes = out.size > 1 ? out[1] : []
        # Assumiamo che siano già non-batched o togliamo il batch dim
        tokens = tokens.first if tokens.is_a?(Array) && tokens.first.is_a?(Array)
        [tokens, boxes]
      end

      def greedy_argmax(logits)
        # logits può essere un array 1D di float
        return 0 if logits.nil? || logits.empty?
        max_i = 0
        max_v = logits[0]
        logits.each_with_index do |v, i|
          if v > max_v
            max_v = v
            max_i = i
          end
        end
        max_i
      end

      # Decodifica la sequenza OTSL in una matrice 2D di celle.
      # Ogni elemento è un Hash { bbox: [x0,y0,x1,y1], span: [rs,cs] } o nil.
      #
      # Regole OTSL (semplificate):
      #   - "fcel" → nuova cella nella posizione corrente
      #   - "lcel" → la cella precedente si estende a destra (colspan++)
      #   - "ucel" → la cella sopra si estende sotto (rowspan++)
      #   - "ecel" → cella vuota di completamento
      #   - "nl"   → nuova riga
      def otsl_to_grid(token_ids, cell_boxes)
        grid = []
        current_row = []
        box_idx = 0
        token_ids.each do |tid|
          name = @vocab[tid] || "<unk>"
          case name
          when "<start>", "<pad>"
            next
          when "<end>"
            break
          when "nl"
            grid << current_row
            current_row = []
          when "fcel"
            bbox = cell_boxes[box_idx]
            box_idx += 1
            current_row << { bbox: bbox, span: [1, 1] }
          when "ecel"
            current_row << nil
          when "lcel"
            if (last = current_row.last)
              last[:span][1] += 1
            end
          when "ucel"
            col = current_row.size
            if grid.last && grid.last[col]
              grid.last[col][:span][0] += 1
            end
            current_row << nil
          when "xcel"
            current_row << nil
          end
        end
        grid << current_row unless current_row.empty?
        grid
      end

      def map_cell_to_pdf(cell_box, table_pdf_bbox, img_w, img_h)
        # cell_box è in coord pixel dell'immagine ritagliata (0..img_w, 0..img_h)
        return table_pdf_bbox if cell_box.nil?
        cx0, cy0, cx1, cy1 = cell_box
        rx0 = cx0 / img_w.to_f
        ry0 = cy0 / img_h.to_f
        rx1 = cx1 / img_w.to_f
        ry1 = cy1 / img_h.to_f
        Document::BBox.new(
          x0:     table_pdf_bbox.x0 + rx0 * table_pdf_bbox.width,
          top:    table_pdf_bbox.top + ry0 * table_pdf_bbox.height,
          x1:     table_pdf_bbox.x0 + rx1 * table_pdf_bbox.width,
          bottom: table_pdf_bbox.top + ry1 * table_pdf_bbox.height
        )
      end

      def text_in_bbox(page, bbox)
        page.text_in_bbox(left: bbox.x0, top: bbox.top,
                           right: bbox.x1, bottom: bbox.bottom).to_s.strip
      rescue StandardError
        ""
      end
    end
  end
end
