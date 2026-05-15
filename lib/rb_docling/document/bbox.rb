# frozen_string_literal: true

module RbDocling
  module Document
    # Bounding box in coordinate PDF (origine in alto-sinistra, come rpdfium
    # restituisce nei char). Tutte le coordinate sono in punti tipografici.
    BBox = Struct.new(:x0, :top, :x1, :bottom, keyword_init: true) do
      def width;  x1 - x0;     end
      def height; bottom - top; end
      def area;   width * height; end
      def cx;     (x0 + x1) / 2.0;     end
      def cy;     (top + bottom) / 2.0; end

      def contains?(other, tol: 0.0)
        other.x0 >= x0 - tol &&
          other.x1 <= x1 + tol &&
          other.top >= top - tol &&
          other.bottom <= bottom + tol
      end

      def intersects?(other)
        !(other.x1 < x0 || other.x0 > x1 || other.bottom < top || other.top > bottom)
      end

      def iou(other)
        return 0.0 unless intersects?(other)
        ix0 = [x0, other.x0].max
        iy0 = [top, other.top].max
        ix1 = [x1, other.x1].min
        iy1 = [bottom, other.bottom].min
        inter = (ix1 - ix0) * (iy1 - iy0)
        union = area + other.area - inter
        union.zero? ? 0.0 : inter.to_f / union
      end

      def to_a
        [x0, top, x1, bottom]
      end

      def self.from_a(arr)
        new(x0: arr[0], top: arr[1], x1: arr[2], bottom: arr[3])
      end

      # Da bbox in pixel di rendering a coordinate PDF.
      # scale = pixel_per_point
      def self.from_pixels(px_bbox, scale:, page_height_pt: nil)
        new(
          x0:     px_bbox[0] / scale,
          top:    px_bbox[1] / scale,
          x1:     px_bbox[2] / scale,
          bottom: px_bbox[3] / scale
        )
      end
    end
  end
end
