//
//  UUCursor.swift
//  UURemoteKit
//

import CoreGraphics

/// The host's pointer shape. As the host sends it, `x` and `y` are the
/// hotspot in the shape's pixels; as a connection reports it, they are the
/// shape's top-left corner on the screen, normalized like the pointer.
public struct UUCursor: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Int
    public var height: Int
    public var image: CGImage?
    public var visible: Bool

    public init(x: Double = 0, y: Double = 0, width: Int = 0, height: Int = 0, image: CGImage? = nil, visible: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.image = image
        self.visible = visible
    }

    public static func == (lhs: UUCursor, rhs: UUCursor) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width
            && lhs.height == rhs.height && lhs.visible == rhs.visible
            && lhs.image === rhs.image
    }

    /// The shape with its top-left at `pointer` − hotspot, normalized. A
    /// hotspot outside the shape is no hotspot: the tip is then the top-left
    /// corner, as on an arrow. Nil until the screen's size is known.
    func placed(at pointer: (x: Double, y: Double), on screen: CGSize) -> UUCursor? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let hotX = (0 ... Double(max(width, 0))).contains(x) ? x : 0
        let hotY = (0 ... Double(max(height, 0))).contains(y) ? y : 0
        var placed = self
        placed.x = pointer.x - hotX / screen.width
        placed.y = pointer.y - hotY / screen.height
        return placed
    }
}
