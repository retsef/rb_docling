# frozen_string_literal: true

require "tempfile"

module RbDocling
  module Layout
    # Layout analysis via modello ONNX (es. RT-DETR addestrato su DocLayNet).
    #
    # Convenzioni input/output (architettura RT-DETR standard, equivalente a
    # quella documentata per il modello docling-ibm-models):
    #
    #   Input:  un tensore float32 di shape [1, 3, H, W], normalizzato ImageNet,
    #           RGB. Per il modello Docling: H=W=640.
    #   Output: tre tensori per immagine:
    #     - labels: int64[N]    indici di classe
    #     - boxes:  float32[N, 4]  in formato [cx, cy, w, h] normalizzato 0..1,
    #                              oppure [x0, y0, x1, y1] - va verificato sul modello
    #     - scores: float32[N]    confidenza 0..1
    #
    # IMPORTANTE: nomi e formato esatti degli output variano tra le versioni di
    # esportazione ONNX di Docling. Il codice qui sotto include rilevamento
    # automatico del formato e accetta un override esplicito.
    class OnnxLayout
      # Classi DocLayNet nell'ordine usato dal training script
      DOCLAYNET_CLASSES = %w[
        Caption Footnote Formula List-item Page-footer Page-header
        Picture Section-header Table Text Title
      ].freeze

      CLASS_TO_NODE_TYPE = {
        "Caption"        => :caption,
        "Footnote"       => :footnote,
        "Formula"        => :formula,
        "List-item"      => :list_item,
        "Page-footer"    => :page_footer,
        "Page-header"    => :page_header,
        "Picture"        => :picture,
        "Section-header" => :section_header,
        "Table"          => :table,
        "Text"           => :text,
        "Title"          => :title
      }.freeze

      DEFAULT_INPUT_SIZE = 640

      def initialize(model_path:, score_threshold: 0.5,
                     input_size: DEFAULT_INPUT_SIZE,
                     classes: DOCLAYNET_CLASSES,
                     box_format: :auto)
        @model_path = model_path
        @session = Models::Loader.session(model_path)
        @score_threshold = score_threshold
        @input_size = input_size
        @classes = classes
        @box_format = box_format

        # Cache info input/output
        @input_name = @session.inputs.first[:name]
        @output_specs = @session.outputs
      end

      # page: rpdfium page
      # Renderizza la pagina, esegue inferenza, mappa box in coordinate PDF.
      # Restituisce Array<Hash> compatibile con HeuristicLayout#analyze.
      #
      # exclude_bboxes: ignorato (RT-DETR è già in grado di riconoscere le
      # tabelle come classe a sé; le tabelle dal layout model hanno priorità).
      def analyze(page, page_no:, exclude_bboxes: [])
        # 1. Render della pagina a immagine in dimensione di input del modello
        page_w_pt = page.width
        page_h_pt = page.height
        scale = compute_scale(page_w_pt, page_h_pt)
        img_w, img_h, rgb_bytes = render_page_rgb(page, scale: scale)

        # 2. Resize a input_size x input_size (con padding per preservare aspect ratio)
        tensor, pad_info = preprocess(rgb_bytes, img_w, img_h)

        # 3. Inferenza
        result = @session.run(nil, { @input_name => tensor })
        detections = parse_outputs(result, pad_info: pad_info,
                                   orig_w_pt: page_w_pt, orig_h_pt: page_h_pt)

        # 4. Per ogni detection, ricava il testo dentro la bbox
        detections.map do |d|
          text = text_in_bbox(page, d[:bbox])
          {
            type: d[:type],
            text: text,
            bbox: d[:bbox],
            font: nil,
            fontsize: nil,
            weight: nil,
            level: d[:type] == :section_header ? 2 : nil,
            page_no: page_no,
            score: d[:score]
          }
        end
      end

      private

      def compute_scale(page_w_pt, page_h_pt)
        # Renderizza in modo che il lato lungo sia >= input_size, con un po' di
        # margine. Il modello fa poi resize interno o noi qui sotto.
        long = [page_w_pt, page_h_pt].max.to_f
        @input_size / long
      end

      def render_page_rgb(page, scale:)
        # rpdfium ha page.render(scale:, output:) -> [w, h, bytes, stride]
        # Output RGBA o RGB. Chiediamo RGB.
        w, h, bytes, _stride = page.render(scale: scale, output: :rgba)
        # Converto RGBA -> RGB
        rgb = String.new(capacity: w * h * 3)
        bytes.each_byte.each_slice(4) do |r, g, b, _a|
          rgb << r.chr << g.chr << b.chr
        end
        [w, h, rgb]
      end

      # Preprocessing standard ImageNet:
      #   - resize con letterbox a input_size
      #   - normalizzazione: mean=[0.485,0.456,0.406], std=[0.229,0.224,0.225]
      #   - layout NCHW: [1, 3, H, W]
      MEAN = [0.485, 0.456, 0.406].freeze
      STD  = [0.229, 0.224, 0.225].freeze

      def preprocess(rgb_bytes, w, h)
        size = @input_size
        # Calcola scale per letterbox
        scale = [size.to_f / w, size.to_f / h].min
        new_w = (w * scale).round
        new_h = (h * scale).round
        pad_x = (size - new_w) / 2
        pad_y = (size - new_h) / 2

        # Resize bilinear nearest semplificato a nearest-neighbor (più rapido in
        # puro Ruby; per qualità superiore, esporre una scelta).
        resized = resize_nearest(rgb_bytes, w, h, new_w, new_h)

        # Costruisco tensor [1, 3, size, size] in float32 con padding
        n = size * size
        # Tre canali separati come array di float
        r_ch = Array.new(n, 0.0)
        g_ch = Array.new(n, 0.0)
        b_ch = Array.new(n, 0.0)

        new_w.times do |x|
          new_h.times do |y|
            src_idx = (y * new_w + x) * 3
            dst_x = x + pad_x
            dst_y = y + pad_y
            dst_idx = dst_y * size + dst_x
            r = resized.getbyte(src_idx)     / 255.0
            g = resized.getbyte(src_idx + 1) / 255.0
            b = resized.getbyte(src_idx + 2) / 255.0
            r_ch[dst_idx] = (r - MEAN[0]) / STD[0]
            g_ch[dst_idx] = (g - MEAN[1]) / STD[1]
            b_ch[dst_idx] = (b - MEAN[2]) / STD[2]
          end
        end

        # Per padding (zone non coperte): valore normalizzato di 0 grigio
        # (l'inizializzazione a 0.0 va bene perché la normalizzazione di 0 darebbe
        # -mean/std, approssimazione tollerabile per padding letterbox).

        tensor = [[r_ch.each_slice(size).to_a,
                   g_ch.each_slice(size).to_a,
                   b_ch.each_slice(size).to_a]]
        pad_info = { scale: scale, pad_x: pad_x, pad_y: pad_y,
                     orig_w: w, orig_h: h, input_size: size,
                     # scale di pagina pt -> px è scala di rendering, da fuori
                   }
        [tensor, pad_info]
      end

      def resize_nearest(src_bytes, sw, sh, dw, dh)
        # src_bytes è una stringa di byte RGB
        out = String.new(capacity: dw * dh * 3)
        x_ratio = sw.to_f / dw
        y_ratio = sh.to_f / dh
        dh.times do |y|
          sy = (y * y_ratio).to_i
          row_start = sy * sw * 3
          dw.times do |x|
            sx = (x * x_ratio).to_i
            i = row_start + sx * 3
            out << src_bytes.getbyte(i).chr
            out << src_bytes.getbyte(i + 1).chr
            out << src_bytes.getbyte(i + 2).chr
          end
        end
        out
      end

      # Interpreta gli output del modello.
      # Diverse esportazioni ONNX di RT-DETR usano nomi/format diversi.
      # Cerchiamo di essere robusti.
      def parse_outputs(result, pad_info:, orig_w_pt:, orig_h_pt:)
        # result è Array di output, nello stesso ordine di @output_specs
        # Mappiamo per nome
        outputs_by_name = {}
        @output_specs.each_with_index do |spec, i|
          outputs_by_name[spec[:name]] = result[i]
        end

        labels, boxes, scores = extract_lbs(outputs_by_name)

        return [] if labels.nil? || boxes.nil? || scores.nil?

        detections = []
        labels.each_with_index do |lbl, i|
          score = scores[i]
          next if score < @score_threshold
          cls_idx = lbl.to_i
          next if cls_idx < 0 || cls_idx >= @classes.size

          # Box in coord normalizzate o pixel del modello
          bx = boxes[i]
          x0, y0, x1, y1 = denormalize_box(bx, pad_info: pad_info,
                                           orig_w_pt: orig_w_pt,
                                           orig_h_pt: orig_h_pt)
          next if x1 <= x0 || y1 <= y0

          cls_name = @classes[cls_idx]
          type = CLASS_TO_NODE_TYPE[cls_name] || :text
          detections << {
            type: type,
            score: score,
            bbox: Document::BBox.new(x0: x0, top: y0, x1: x1, bottom: y1)
          }
        end

        detections
      end

      def extract_lbs(out)
        # Cerca per nome convenzionale, fallback su shape
        labels = out["labels"] || out["pred_labels"] || out["classes"]
        boxes  = out["boxes"]  || out["pred_boxes"]  || out["bboxes"]
        scores = out["scores"] || out["pred_scores"] || out["confidences"]

        # Fallback: se non riconosce i nomi, prova per shape
        if labels.nil? || boxes.nil? || scores.nil?
          out.each do |name, v|
            shape = array_shape(v)
            case shape.size
            when 1
              if v.first.is_a?(Integer)
                labels ||= v
              else
                scores ||= v
              end
            when 2
              boxes ||= v if shape[1] == 4
            end
          end
        end

        # I tensori onnxruntime-ruby vengono restituiti come array innestati.
        # Spesso il batch dim è presente: [[...]] invece di [...].
        labels = unwrap_batch(labels)
        boxes  = unwrap_batch(boxes)
        scores = unwrap_batch(scores)
        [labels, boxes, scores]
      end

      def unwrap_batch(arr)
        return nil if arr.nil?
        # Se è [[...]], togli un livello
        return arr.first if arr.is_a?(Array) && arr.size == 1 && arr.first.is_a?(Array)
        arr
      end

      def array_shape(a)
        s = []
        cur = a
        while cur.is_a?(Array)
          s << cur.size
          cur = cur.first
        end
        s
      end

      def denormalize_box(box, pad_info:, orig_w_pt:, orig_h_pt:)
        # box può essere [cx, cy, w, h] normalizzato 0..1 oppure [x0,y0,x1,y1]
        # in pixel della input size.
        size = pad_info[:input_size]
        case detect_box_format(box, size)
        when :xyxy_norm
          x0n, y0n, x1n, y1n = box
          x0 = x0n * size; y0 = y0n * size; x1 = x1n * size; y1 = y1n * size
        when :cxcywh_norm
          cx, cy, w, h = box
          x0 = (cx - w/2.0) * size
          y0 = (cy - h/2.0) * size
          x1 = (cx + w/2.0) * size
          y1 = (cy + h/2.0) * size
        when :xyxy_px
          x0, y0, x1, y1 = box
        else # cxcywh_px
          cx, cy, w, h = box
          x0 = cx - w/2.0; y0 = cy - h/2.0; x1 = cx + w/2.0; y1 = cy + h/2.0
        end

        # Rimuovi padding e riporta a coord rendering originali
        x0 = (x0 - pad_info[:pad_x]) / pad_info[:scale]
        y0 = (y0 - pad_info[:pad_y]) / pad_info[:scale]
        x1 = (x1 - pad_info[:pad_x]) / pad_info[:scale]
        y1 = (y1 - pad_info[:pad_y]) / pad_info[:scale]

        # Da pixel di rendering a punti PDF
        px_per_pt_x = pad_info[:orig_w].to_f / orig_w_pt
        px_per_pt_y = pad_info[:orig_h].to_f / orig_h_pt
        [x0 / px_per_pt_x, y0 / px_per_pt_y, x1 / px_per_pt_x, y1 / px_per_pt_y]
      end

      def detect_box_format(box, size)
        return @box_format unless @box_format == :auto
        # Heuristic: se tutti i valori sono in 0..1, è normalizzato
        max = box.max
        normalized = max <= 1.5
        # Se w/h ragionevoli e min < max/2, probabilmente xyxy
        looks_xyxy = (box[2] > box[0]) && (box[3] > box[1])
        if normalized
          looks_xyxy ? :xyxy_norm : :cxcywh_norm
        else
          looks_xyxy ? :xyxy_px : :cxcywh_px
        end
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
