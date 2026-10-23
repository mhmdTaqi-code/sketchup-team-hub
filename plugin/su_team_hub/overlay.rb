# Viewport overlay: a colored box + the owner's name around every reserved
# object, so everyone sees at a glance who is working on what.

module TeamHub
  if defined?(Sketchup::Overlay)
    class LockOverlay < Sketchup::Overlay
      EDGES = [[0, 1], [1, 3], [3, 2], [2, 0], [4, 5], [5, 7], [7, 6], [6, 4],
               [0, 4], [1, 5], [2, 6], [3, 7]].freeze

      def initialize(session)
        super('teamhub.reservations', 'Team Hub — الحجوزات',
              description: 'يبين منو حاجز كل عنصر بالمشروع المشترك')
        @session = session
      end

      def getExtents
        bb = Geom::BoundingBox.new
        @session.overlay_items.each do |ent, *|
          bb.add(ent.bounds) if ent.valid?
        end
        bb
      end

      def draw(view)
        @session.overlay_items.each do |ent, color, label, mine|
          next unless ent.valid? && ent.visible? && ent.layer.visible?
          bb = ent.bounds
          next if bb.empty?
          pts = EDGES.flat_map { |a, b| [bb.corner(a), bb.corner(b)] }
          view.line_stipple = mine ? '_' : ''
          view.line_width = mine ? 1.5 : 2.5
          view.drawing_color = color
          view.draw(GL_LINES, pts)
          top = Geom::Point3d.new(bb.center.x, bb.center.y, bb.max.z)
          screen = view.screen_coords(top)
          view.draw_text(screen, label, size: 11, bold: true, color: color,
                                        align: TextAlignCenter, vertical_align: TextVerticalAlignBaseline)
        end
      rescue StandardError
        nil
      end
    end
  end

  def self.attach_overlay(model, session)
    return nil unless defined?(Sketchup::Overlay)
    model.overlays.each { |o| model.overlays.remove(o) if o.overlay_id == 'teamhub.reservations' }
    overlay = LockOverlay.new(session)
    model.overlays.add(overlay)
    overlay.enabled = true
    overlay
  rescue StandardError => e
    log_error(e)
    nil
  end

  def self.detach_overlay(model, overlay)
    model.overlays.remove(overlay) if overlay
  rescue StandardError
    nil
  end
end
