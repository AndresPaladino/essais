import AppKit
import QuartzCore

/// Moves the paper with critically damped springs, recalculated every frame of the display: a move
/// starts from whatever speed there is and a new one takes over without a seam. The display link runs
/// only while something is moving, so at rest it costs nothing. The hand always wins: a pinch or a
/// scroll stops it. Pinching and scrolling themselves are the system's and aren't touched.
@MainActor
final class PaperCamera: NSObject {
    private struct Spring {
        var value: CGFloat = 0, target: CGFloat = 0, velocity: CGFloat = 0
        let stiffness: CGFloat

        // The exact solution, stable at any frame rate.
        mutating func step(_ dt: CGFloat) {
            let e = exp(-stiffness * dt), d = value - target, c = velocity + stiffness * d
            value = target + (d + c * dt) * e
            velocity = (velocity - c * stiffness * dt) * e
        }
        func settled(tolerance: CGFloat) -> Bool { abs(value - target) < tolerance && abs(velocity) < tolerance * 4 }
        mutating func finish() { value = target; velocity = 0 }
    }

    private let scrollView: NSScrollView
    private var clip: NSClipView { scrollView.contentView }
    private var y = Spring(stiffness: 13)        // the paper rising to the next line
    private var x = Spring(stiffness: 9)         // sideways: follows the caret, swoops back when the line breaks
    private var zoom = Spring(stiffness: 11)
    private var anchor = NSPoint.zero
    private var moving = false, zooming = false
    private var done: (() -> Void)?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    var isMoving: Bool { moving || zooming }

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
    }

    /// Glides to a point of the paper. `done` runs when it arrives, or when something else takes over.
    func move(to point: NSPoint, done newDone: (() -> Void)? = nil) {
        finishCallback()
        done = newDone
        if !moving {
            let origin = clip.bounds.origin
            y.value = origin.y; x.value = origin.x
            y.velocity = 0; x.velocity = 0
        }
        y.target = point.y; x.target = point.x
        moving = true
        run()
    }

    /// Closer or farther, keeping `point` (in paper coordinates) where it is on screen.
    func zoom(to value: CGFloat, around point: NSPoint) {
        finishCallback()
        moving = false
        if !zooming { zoom.value = scrollView.magnification; zoom.velocity = 0 }
        zoom.target = value
        anchor = point
        zooming = true
        run()
    }

    /// Everything stops where it is. What was waiting for the arrival still happens.
    func stop() {
        moving = false; zooming = false
        link?.isPaused = true
        finishCallback()
    }

    private func finishCallback() {
        let waiting = done
        done = nil
        waiting?()
    }

    private func run() {
        if link == nil {
            let new = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
            new.add(to: .main, forMode: .common)
            link = new
        }
        if link?.isPaused != false { last = 0 }
        link?.isPaused = false
    }

    /// To whole device pixels at the current zoom: text sliding between pixels shimmers.
    private func aligned(_ v: CGFloat) -> CGFloat {
        let k = (scrollView.window?.backingScaleFactor ?? 2) * scrollView.magnification
        return (v * k).rounded() / k
    }

    @objc private func tick(_ link: CADisplayLink) {
        #if QA
        let started = CACurrentMediaTime(), gap = link.timestamp - last, wasZooming = zooming
        defer { Self.bench?(wasZooming, gap, CACurrentMediaTime() - started) }
        #endif
        let dt = CGFloat(min(0.05, last == 0 ? link.duration : link.timestamp - last))
        defer { last = link.timestamp }
        if zooming {
            zoom.step(dt)
            let arrived = zoom.settled(tolerance: 0.0015)
            if arrived { zoom.finish() }
            scrollView.setMagnification(zoom.value, centeredAt: anchor)
            if arrived { zooming = false }
        }
        if moving {
            y.step(dt); x.step(dt)
            let arrived = y.settled(tolerance: 0.25) && x.settled(tolerance: 0.25)
            if arrived { y.finish(); x.finish() }
            clip.setBoundsOrigin(NSPoint(x: aligned(x.value), y: aligned(y.value)))
            scrollView.reflectScrolledClipView(clip)
            if arrived { moving = false }
        }
        if !isMoving {
            link.isPaused = true
            finishCallback()
        }
    }

    #if QA
    /// (zooming, time since the last frame, time spent in this one)
    static var bench: ((Bool, CFTimeInterval, CFTimeInterval) -> Void)?
    #endif
}
