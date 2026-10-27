import SwiftUI
import QuartzCore

// Home scrolls the card of what a clicked display shows to the middle of the library (LibraryReveal).
//
// ScrollViewProxy silently drops a scroll to a card the lazy grid has not laid out (one far from view) when the scroll
// is asked for in the update the click's selection change causes, or, at times, while the library still moves: an
// animated scroll under way then just ends where it was going. So a reveal starts its scroll on a later run loop turn,
// and once the library rests checks that the card ended up in place, scrolling again if not. Only the latest click's
// card counts. Rest is measured by the offset, not the scroll phase: a scroll with no distance to go reports .animating
// and never .idle again.

/// Plain reference state: it changes on every scroll step, and none of it is drawn.
@MainActor
final class LibraryReveal {
    /// The coordinate space of the library's content, which the current card's frame is measured in.
    static let contentSpace = "LibraryReveal.content"
    /// Seconds without an offset change after which the library counts as resting. A scroll's first step comes within
    /// a frame or a few, so a scroll that has not moved by then was dropped.
    private static let restTime: CFTimeInterval = 0.12
    /// Scrolls a reveal may take before it gives up, such as when the card is not listed.
    private static let maxScrolls = 4

    struct CardFrame: Equatable {
        let frame: CGRect
        let contentWidth: CGFloat   // a reflow to another width moves the cards
    }

    private var target: UUID?
    private var scrolls = 0
    private var proxy: ScrollViewProxy?
    /// The frames of the cards marked current (libraryRevealCard).
    private var currentCards: [UUID: CardFrame] = [:]
    private var geometry: ScrollGeometry?
    private var lastMove: CFTimeInterval = 0
    private var step: DispatchWorkItem?

    /// Scrolls the card with `id` to the middle of the library, as near as the ends of the content allow.
    func reveal(_ id: UUID, with proxy: ScrollViewProxy) {
        target = id
        scrolls = 0
        self.proxy = proxy
        schedule(after: 0)
    }

    func scrolled(_ geometry: ScrollGeometry) {
        if geometry.contentOffset != self.geometry?.contentOffset { lastMove = CACurrentMediaTime() }
        self.geometry = geometry
    }

    /// The user scrolling the library ends a reveal, which would otherwise pull the view back once they stop.
    func phaseChanged(to phase: ScrollPhase) {
        guard phase == .tracking || phase == .interacting else { return }
        target = nil
        step?.cancel()
    }

    func card(_ id: UUID, movedTo frame: CardFrame?) {
        currentCards[id] = frame
    }

    private func schedule(after delay: CFTimeInterval) {
        step?.cancel()
        let step = DispatchWorkItem { [weak self] in self?.advance() }
        self.step = step
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: step)
    }

    /// A new target scrolls at once, cutting short any scroll under way. Whether it arrived is checked only while the
    /// library rests: moving, it may pass through the target's place on its way elsewhere.
    private func advance() {
        guard let target, let proxy else { return }
        let resting = CACurrentMediaTime() - lastMove
        if resting < Self.restTime, scrolls > 0 {
            schedule(after: Self.restTime - resting)
            return
        }
        if resting >= Self.restTime, isInPlace(target) || scrolls >= Self.maxScrolls {
            self.target = nil
            return
        }
        scrolls += 1
        lastMove = CACurrentMediaTime()
        withAnimation(WMMotion.content) { proxy.scrollTo(target, anchor: .center) }
        schedule(after: Self.restTime)
    }

    /// The card is in the middle of the view, or as near as the ends of the content let it get.
    private func isInPlace(_ id: UUID) -> Bool {
        guard let geometry, let card = currentCards[id],
              abs(card.contentWidth - geometry.contentSize.width) < 0.5 else { return false }
        let distance = card.frame.midY - geometry.visibleRect.midY
        if abs(distance) <= 1 { return true }
        let offset = geometry.contentOffset.y
        let top = -geometry.contentInsets.top
        let bottom = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        return distance < 0 ? offset <= top + 0.5 : offset >= bottom - 0.5
    }
}

extension View {
    /// Marks a library card for `reveal`: while `current` (the selected display shows it), its frame is tracked.
    func libraryRevealCard(_ id: UUID, current: Bool, in reveal: LibraryReveal) -> some View {
        onGeometryChange(for: LibraryReveal.CardFrame?.self) { geometry in
            let space = NamedCoordinateSpace.named(LibraryReveal.contentSpace)
            guard current, let content = geometry.bounds(of: space) else { return nil }
            return LibraryReveal.CardFrame(frame: geometry.frame(in: space), contentWidth: content.width)
        } action: { frame in
            reveal.card(id, movedTo: frame)
        }
    }
}
