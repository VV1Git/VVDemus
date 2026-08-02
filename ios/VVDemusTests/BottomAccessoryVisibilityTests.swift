import SwiftUI
import UIKit
import XCTest

@testable import VVDemus

/// `tabViewBottomAccessory` draws its glass capsule whenever the modifier is attached, even if
/// the content closure produces nothing — so an empty capsule sat above the tab bar the whole
/// time nothing was playing. The fix is to attach the modifier only while there is a track,
/// which raises the question this file exists to answer: does flipping a modifier on and off
/// around a `TabView` cost the tab views their identity?
///
/// If it does, the first song of a session would silently pop Search and Library back to their
/// root screens, which is far worse than the capsule. A harness is used rather than `RootView`
/// because `PlayerService.currentTrack` is `private(set)` and can only be moved by real
/// playback; the question is about SwiftUI's structural identity rules, and the harness models
/// exactly the shape `RootView` uses.
@MainActor
final class BottomAccessoryVisibilityTests: XCTestCase {
    /// Observable on purpose: a plain reference cell behind a `Binding` never invalidates the
    /// view, so the toggle silently does nothing and every assertion after it passes vacuously.
    final class Flag: ObservableObject {
        @Published var showsAccessory = false
    }

    private struct Harness: View {
        @ObservedObject var flag: Flag
        /// Whether to attach the accessory the way `RootView` does, or the conditional way that
        /// looks equivalent and isn't.
        var conditionallyAttached = false

        var body: some View {
            let tabs = TabView {
                Tab("Home", systemImage: "house.fill") {
                    NavigationStack { Text("home") }
                }
                Tab("Search", systemImage: "magnifyingglass") {
                    NavigationStack { Text("search") }
                }
            }
            if conditionallyAttached {
                tabs.conditionallyAttachedAccessory(showing: flag.showsAccessory)
            } else {
                tabs.accessory(showing: flag.showsAccessory)
            }
        }
    }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// The conditional attachment that `RootView` deliberately avoids. Documented as a test
    /// rather than a comment because it is the fix anyone would reach for first, and the damage
    /// it does is invisible until you notice a screen you were on has reset itself.
    func testConditionallyAttachingTheAccessoryThrowsTheTabsAway() throws {
        let flag = Flag()
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(
            rootView: Harness(flag: flag, conditionallyAttached: true)
        )
        window.makeKeyAndVisible()
        settle(window)

        let before = try XCTUnwrap(Self.tabBarController(in: window))
        flag.showsAccessory = true
        settle(window)
        let after = try XCTUnwrap(Self.tabBarController(in: window))

        XCTAssertNotIdentical(before, after,
                              "Conditional attachment no longer rebuilds the tab bar controller. "
                                  + "If SwiftUI has changed this, RootView's comment and its use "
                                  + "of isEnabled: are both out of date.")
    }

    func testTogglingTheAccessoryKeepsTheTabsAlive() throws {
        let flag = Flag()
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIHostingController(rootView: Harness(flag: flag))
        window.makeKeyAndVisible()
        settle(window)

        let before = try XCTUnwrap(Self.tabBarController(in: window))
        let childrenBefore = try XCTUnwrap(before.viewControllers)
        // Snapshotted, not held by reference: `before.view` and `after.view` are the same object
        // when identity is preserved, so comparing them live would compare a hierarchy with
        // itself and match no matter what happened.
        let namesWithout = Self.classNames(under: before.view)

        flag.showsAccessory = true
        settle(window)

        let after = try XCTUnwrap(Self.tabBarController(in: window))
        let namesWith = Self.classNames(under: after.view)

        // Guards the rest of the test: if the toggle never reached SwiftUI, nothing below means
        // anything. An unobservable flag behind a Binding fails exactly this way, silently.
        XCTAssertNotEqual(namesWith, namesWithout,
                          "Attaching the accessory changed nothing in the hierarchy, so the "
                              + "toggle isn't reaching SwiftUI and this test proves nothing.")
        XCTAssertIdentical(before, after,
                           "Attaching the accessory rebuilt the tab bar controller — every tab's "
                               + "navigation stack and scroll position would be thrown away the "
                               + "moment the first song starts.")
        XCTAssertEqual(childrenBefore.count, after.viewControllers?.count)
        for (old, new) in zip(childrenBefore, after.viewControllers ?? []) {
            XCTAssertIdentical(old, new, "A tab's view controller was replaced.")
        }

        // And back: with nothing playing the accessory has to actually go away again, which is
        // the bug this whole arrangement exists to fix.
        flag.showsAccessory = false
        settle(window)
        XCTAssertEqual(Self.classNames(under: before.view), namesWithout,
                       "The accessory left something behind when it was detached.")
    }

    private func settle(_ window: UIWindow) {
        window.rootViewController?.view.setNeedsLayout()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private static func classNames(under view: UIView) -> Set<String> {
        var names: Set<String> = []
        var stack = [view]
        while let current = stack.popLast() {
            names.insert(String(describing: type(of: current)))
            stack.append(contentsOf: current.subviews)
        }
        return names
    }

    private static func tabBarController(in window: UIWindow) -> UITabBarController? {
        guard let root = window.rootViewController else { return nil }
        return find(in: root)
    }

    private static func find(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = find(in: child) { return found }
        }
        return nil
    }
}

private extension View {
    /// The same attachment `RootView` uses: always present, gated by `isEnabled`.
    func accessory(showing: Bool) -> some View {
        tabViewBottomAccessory(isEnabled: showing) { Text("now playing") }
    }
}

/// The conditional attachment that looks like the obvious fix, kept so the test below can show
/// what it costs. Not used by the app.
private extension View {
    @ViewBuilder
    func conditionallyAttachedAccessory(showing: Bool) -> some View {
        if showing {
            tabViewBottomAccessory { Text("now playing") }
        } else {
            self
        }
    }
}
