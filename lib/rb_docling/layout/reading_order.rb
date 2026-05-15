# frozen_string_literal: true

module RbDocling
  module Layout
    # Determina l'ordine di lettura su pagine multi-colonna.
    # Algoritmo: clustering 1D delle posizioni x0, poi top-to-bottom per colonna,
    # poi colonna-per-colonna left-to-right.
    class ReadingOrder
      # Soglia (in punti) per considerare due blocchi nella stessa colonna.
      COLUMN_TOL = 25.0

      def self.sort(blocks)
        return blocks if blocks.size <= 1

        # Cluster delle x0
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

        # Ordino i cluster per x media (left-to-right)
        clusters.sort_by! { |c| c.map { |b| b[:bbox].x0 }.sum.to_f / c.size }

        # Dentro ogni colonna, top-to-bottom
        clusters.flat_map { |c| c.sort_by { |b| b[:bbox].top } }
      end
    end
  end
end
