# frozen_string_literal: true

module RbDocling
  module Layout
    # Determina l'ordine di lettura su una pagina.
    #
    # Tre strategie a cascata, selezionate da `strategy: :auto`:
    #
    #   1. STRUCT-TREE (livello 1): se la pagina è un PDF tagged
    #      (PDF/UA, export Word/InDesign accessibility-friendly), usa
    #      l'ordine d'autore dichiarato nello StructTreeRoot via
    #      Marked Content IDs. Più affidabile di qualsiasi euristica.
    #
    #   2. ML (livello 2): se è disponibile l'output di un layout model
    #      (DocLayNet RT-DETR via OnnxLayout), usa l'ordine naturale
    #      delle detection (i modelli RT-DETR emettono già in reading
    #      order per i casi tipici). Applica un post-processing minimo
    #      di stabilità (sort per detection_index, top come tiebreaker).
    #
    #   3. GEOMETRIC (livello 3, fallback): cluster 1D delle posizioni
    #      x0, poi top-to-bottom per colonna, poi left-to-right tra
    #      colonne. Funziona su layout 1-3 colonne semplici.
    #
    # Le strategie sono "skippabili": un blocco che il livello 1 non
    # riesce a posizionare (es. zero MCID match) viene passato al
    # fallback (geometric) e inserito per posizione verticale.
    class ReadingOrder
      # Soglia (in punti) per considerare due blocchi nella stessa colonna.
      COLUMN_TOL = 25.0

      # Pubblico. Backward-compatibile: chiamare senza kwargs equivale
      # al vecchio comportamento geometric-only.
      #
      # @param blocks [Array<Hash>] blocchi con :bbox
      # @param page [Rpdfium::Page, nil] pagina di provenienza; se passata,
      #   abilita il livello struct-tree.
      # @param ml_output [Array<Hash>, nil] output di un layout ML; se
      #   passato, abilita il livello ML come fallback prima del geometric.
      # @param strategy [Symbol] :auto | :struct | :ml | :geometric
      def self.sort(blocks, page: nil, ml_output: nil, strategy: :auto)
        return blocks if blocks.size <= 1

        case strategy
        when :geometric
          sort_geometric(blocks)
        when :struct
          ordered, orphans = sort_by_struct_tree(blocks, page)
          ordered + sort_geometric(orphans)
        when :ml
          sort_by_ml(blocks, ml_output)
        when :auto
          auto_sort(blocks, page, ml_output)
        else
          raise ArgumentError, "strategy non supportata: #{strategy.inspect}"
        end
      end

      # Cascata: struct-tree → ml → geometric.
      def self.auto_sort(blocks, page, ml_output)
        if page
          ordered, orphans = sort_by_struct_tree(blocks, page)
          if ordered.any?
            # Orfani: prova ML se disponibile, altrimenti geometric, e
            # vengono accodati dopo i blocchi posizionati dal tree.
            fallback ||= sort_by_ml(orphans, ml_output) if ml_output
            fallback ||= sort_geometric(orphans)
            return ordered + fallback
          end
        end

        return sort_by_ml(blocks, ml_output) if ml_output

        sort_geometric(blocks)
      end

      # --- Livello 1: STRUCT-TREE ---------------------------------------

      # Restituisce [ordered, orphans]. Se la pagina non è tagged o il
      # tree è vuoto, ordered è vuoto e orphans = blocks.
      def self.sort_by_struct_tree(blocks, page)
        return [[], blocks] unless page&.respond_to?(:struct_tree)

        page.struct_tree do |tree|
          return [[], blocks] if tree.nil? || tree.empty?

          mcid_order = build_mcid_order(tree)
          return [[], blocks] if mcid_order.empty?

          obj_to_mcid = build_obj_to_mcid(page)
          return [[], blocks] if obj_to_mcid.empty?

          chars = page.chars

          ordered_pairs = []
          orphans = []
          blocks.each do |block|
            bbox = block[:bbox]
            unless bbox
              orphans << block
              next
            end

            mcids = mcids_for_block(chars, bbox, obj_to_mcid)
            positions = mcids.filter_map { |m| mcid_order[m] }
            if positions.empty?
              orphans << block
            else
              ordered_pairs << [positions.min, block]
            end
          end

          ordered = ordered_pairs.sort_by(&:first).map(&:last)
          return [ordered, orphans]
        end
      rescue StandardError => e
        warn "[ReadingOrder] struct-tree fallback su errore: #{e.message}"
        [[], blocks]
      end

      # Costruisce {mcid => integer position} via DFS del tree.
      # Un element può avere più MCID (raro ma legale): ognuno riceve
      # la stessa position dell'element padre, così blocchi che cadono
      # nello stesso element finiscono adiacenti.
      def self.build_mcid_order(tree)
        order = {}
        pos = 0
        tree.walk do |el|
          ids = el.marked_content_ids
          next if ids.empty?

          ids.each do |m|
            order[m] = pos unless order.key?(m)
          end
          pos += 1
        end
        order
      end

      # {ffi_address => mcid} reversando page.marked_content_regions.
      def self.build_obj_to_mcid(page)
        map = {}
        regions = page.marked_content_regions
        regions.each do |mcid, objs|
          objs.each do |obj|
            addr = obj.respond_to?(:address) ? obj.address : nil
            map[addr] = mcid if addr
          end
        end
        map
      end

      # Insieme degli mcid dei chars che cadono dentro bbox.
      def self.mcids_for_block(chars, bbox, obj_to_mcid)
        result = []
        seen = {}
        chars.each do |c|
          next unless char_in_bbox?(c, bbox)

          obj_id = c[:text_obj_id]
          next unless obj_id

          mcid = obj_to_mcid[obj_id]
          next unless mcid
          next if seen[mcid]

          seen[mcid] = true
          result << mcid
        end
        result
      end

      def self.char_in_bbox?(c, bbox)
        cx = (c[:x0] + c[:x1]) / 2.0
        cy = (c[:top] + c[:bottom]) / 2.0
        cx >= bbox.x0 && cx <= bbox.x1 && cy >= bbox.top && cy <= bbox.bottom
      end

      # --- Livello 2: ML ------------------------------------------------

      # Ordina per :detection_index quando presente (l'ordine di emissione
      # del modello layout). Tiebreaker: top, x0. Blocchi senza detection
      # index (es. tabelle estratte separatamente) vengono interpolati
      # per posizione verticale.
      def self.sort_by_ml(blocks, ml_output = nil)
        # ml_output è informativo: nel design attuale i detection_index
        # sono già attaccati ai blocchi da OnnxLayout. Lo accettiamo per
        # futura estensibilità (es. passare detection box raw separate
        # dai blocchi finali).
        _ = ml_output

        with_idx, without_idx = blocks.partition { |b| b[:detection_index] }
        return sort_geometric(blocks) if with_idx.empty?

        sorted_idx = with_idx.sort_by do |b|
          [b[:detection_index], b[:bbox]&.top || 0, b[:bbox]&.x0 || 0]
        end
        return sorted_idx if without_idx.empty?

        # Inserisci i without_idx nella posizione verticalmente più
        # adatta tra i sorted_idx.
        insert_by_vertical_position(sorted_idx, without_idx)
      end

      def self.insert_by_vertical_position(ordered, orphans)
        result = ordered.dup
        orphans.each do |orphan|
          y = orphan[:bbox]&.top
          if y.nil?
            result << orphan
            next
          end

          idx = result.find_index { |b| (b[:bbox]&.top || Float::INFINITY) > y }
          if idx
            result.insert(idx, orphan)
          else
            result << orphan
          end
        end
        result
      end

      # --- Livello 3: GEOMETRIC (algoritmo originale) -------------------

      def self.sort_geometric(blocks)
        return blocks if blocks.size <= 1

        sorted_by_x = blocks.sort_by { |b| b[:bbox].x0 }
        clusters = []
        current = [sorted_by_x.first]
        sorted_by_x.each_cons(2) do |a, b|
          if (b[:bbox].x0 - a[:bbox].x0).abs <= COLUMN_TOL
            current << b
          else
            clusters << current
            current = [b]
          end
        end
        clusters << current unless current.empty?

        clusters.sort_by! { |c| c.map { |b| b[:bbox].x0 }.sum.to_f / c.size }
        clusters.flat_map { |c| c.sort_by { |b| b[:bbox].top } }
      end
    end
  end
end
