import QtQuick
import QtQuick.Shapes
import "lib/Palette.js" as Palette

// opencode's own mark, drawn rather than shipped. A bitmap would need a recolour pass
// to follow the theme and would still be one fixed size; two paths cost neither and
// let the frame and the cursor take separate colours, which is where the signal lives.
// The bar and the panel both mount this, so the two can never drift apart.
Item {
  id: mark

  property real size: 16
  property color frameColor: "white"
  property color cursorColor: "grey"
  property real cursorFill: Palette.MARK_CURSOR_FILL
  property int colorDuration: 160

  // Snapped to whole pixels: the mark is nothing but axis-aligned edges, and a
  // fractional box is what makes a small logo look furry.
  height: Math.round(size)
  width: Math.round(height * Palette.MARK_VIEW_W / Palette.MARK_VIEW_H)

  Shape {
    anchors.fill: parent

    transform: Scale {
      xScale: mark.width / Palette.MARK_VIEW_W
      yScale: mark.height / Palette.MARK_VIEW_H
    }

    ShapePath {
      fillColor: mark.frameColor
      fillRule: ShapePath.OddEvenFill
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: Palette.MARK_FRAME }

      Behavior on fillColor { ColorAnimation { duration: mark.colorDuration; easing.type: Easing.OutCubic } }
    }

    ShapePath {
      fillColor: mark.cursorColor
      strokeColor: "transparent"
      strokeWidth: 0
      PathSvg { path: Palette.markCursorPath(mark.cursorFill) }

      Behavior on fillColor { ColorAnimation { duration: mark.colorDuration; easing.type: Easing.OutCubic } }
    }
  }
}
