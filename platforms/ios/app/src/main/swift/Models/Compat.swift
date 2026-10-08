// Compat.swift — back-deployment shims so the SwiftUI frontend runs on iOS 16
// SPDX-License-Identifier: GPL-3.0+
//
// The UI was written against iOS 17 (Observation, two-value `onChange`,
// `sensoryFeedback`, scroll-position APIs ...) and iOS 26 (Liquid Glass). The
// app now deploys back to iOS 16.0, so every call to one of those goes through
// this file and the availability decision is made in exactly one place.
//
// Rule of thumb: newer systems get the real API unchanged; iOS 16 gets the
// closest thing that exists there.

import Combine
import SwiftUI
import UIKit

// MARK: - Observation replacement

/// `@ObservedObject` for an optional model. SwiftUI has no optional form, and the
/// controller router is passed down as `MenuControllerInputRouter?`. The relay
/// forwards the model's `objectWillChange` to the view that owns the wrapper, so an
/// optional model invalidates its readers exactly as the iOS 17 Observation did.
@propertyWrapper
struct ObservedOptional<Object: ObservableObject>: DynamicProperty {
    @StateObject private var relay = ObservedOptionalRelay()
    private var object: Object?

    init(wrappedValue: Object?) {
        object = wrappedValue
    }

    var wrappedValue: Object? {
        get { object }
        set { object = newValue }
    }

    @MainActor
    func update() {
        relay.attach(to: object)
    }
}

private final class ObservedOptionalRelay: ObservableObject {
    private weak var current: AnyObject?
    private var subscription: AnyCancellable?

    func attach<Object: ObservableObject>(to object: Object?) {
        guard current !== (object as AnyObject?) else { return }
        current = object
        subscription = object?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - onChange

/// iOS 16 `onChange` only reports the new value. This keeps the old one in state so
/// call sites can use the two-value form on every system.
private struct CompatOnChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void

    @State private var previous: Value
    @State private var didRunInitial = false

    init(value: Value, initial: Bool, action: @escaping (Value, Value) -> Void) {
        self.value = value
        self.initial = initial
        self.action = action
        _previous = State(initialValue: value)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: value, initial: initial, action)
        } else {
            content
                .onAppear {
                    // `initial: true` fires once, when the view first appears, with
                    // old and new equal - the same as the iOS 17 behaviour.
                    guard initial, !didRunInitial else { return }
                    didRunInitial = true
                    action(value, value)
                }
                .onChange(of: value) { newValue in
                    let oldValue = previous
                    previous = newValue
                    action(oldValue, newValue)
                }
        }
    }
}

extension View {
    /// `onChange(of:initial:_:)` with the iOS 17 signature, usable from iOS 16.
    func compatOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        modifier(CompatOnChangeModifier(value: value, initial: initial, action: action))
    }
}

// MARK: - Presentation

extension View {
    /// `presentationBackground` arrived in iOS 16.4. On 16.0-16.3 a sheet keeps its
    /// default background, so the translucent sheets this app builds become opaque
    /// there instead of failing to build.
    @ViewBuilder
    func compatPresentationBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(style)
        } else {
            self
        }
    }
}

// MARK: - Empty state

/// `ContentUnavailableView(_:systemImage:description:)` on iOS 17+; the same idea
/// built by hand on iOS 16.
struct CompatContentUnavailable: View {
    let title: String
    let systemImage: String
    let description: Text?

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        if #available(iOS 17.0, *) {
            if let description {
                ContentUnavailableView(title, systemImage: systemImage, description: description)
            } else {
                ContentUnavailableView(title, systemImage: systemImage)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.weight(.bold))
                if let description {
                    description
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Scroll and focus

/// Mirrors `ContentMarginPlacement` (iOS 17) so call sites keep the same spelling.
enum CompatContentMarginPlacement {
    case automatic
    case scrollContent
    case scrollIndicators
}

/// Mirrors `ScrollBounceBehavior` (iOS 16.4).
enum CompatScrollBounceBehavior {
    case automatic
    case always
    case basedOnSize
}

extension View {
    /// `contentMargins(_:_:for:)`. Before iOS 17 a non-zero margin is approximated with a
    /// safe-area inset, which a scroll view treats as extra content inset; a zero margin is
    /// a no-op because earlier systems add none.
    @ViewBuilder
    func compatContentMargins(
        _ edges: Edge.Set,
        _ length: CGFloat?,
        for placement: CompatContentMarginPlacement = .automatic
    ) -> some View {
        if #available(iOS 17.0, *) {
            switch placement {
            case .automatic:
                contentMargins(edges, length, for: .automatic)
            case .scrollContent:
                contentMargins(edges, length, for: .scrollContent)
            case .scrollIndicators:
                contentMargins(edges, length, for: .scrollIndicators)
            }
        } else if let length, length != 0, placement != .scrollIndicators {
            modifier(LegacyContentInset(edges: edges, length: length))
        } else {
            self
        }
    }

    /// `scrollBounceBehavior(_:axes:)` arrived in iOS 16.4; earlier systems keep the default.
    @ViewBuilder
    func compatScrollBounceBehavior(
        _ behavior: CompatScrollBounceBehavior,
        axes: Axis.Set = [.vertical]
    ) -> some View {
        if #available(iOS 16.4, *) {
            switch behavior {
            case .automatic:
                scrollBounceBehavior(.automatic, axes: axes)
            case .always:
                scrollBounceBehavior(.always, axes: axes)
            case .basedOnSize:
                scrollBounceBehavior(.basedOnSize, axes: axes)
            }
        } else {
            self
        }
    }

    /// `scrollTargetLayout()` only matters together with the iOS 17 scroll-position APIs.
    @ViewBuilder
    func compatScrollTargetLayout() -> some View {
        if #available(iOS 17.0, *) {
            scrollTargetLayout()
        } else {
            self
        }
    }

    /// `focusEffectDisabled()` (iOS 17). Earlier systems draw no keyboard focus ring here.
    @ViewBuilder
    func compatFocusEffectDisabled() -> some View {
        if #available(iOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }

    /// `focusable(_:)` (iOS 17).
    @ViewBuilder
    func compatFocusable(_ isFocusable: Bool) -> some View {
        if #available(iOS 17.0, *) {
            focusable(isFocusable)
        } else {
            self
        }
    }

    /// `buttonRepeatBehavior(_:)` (iOS 17); a plain button on iOS 16.
    @ViewBuilder
    func compatButtonRepeat(_ enabled: Bool) -> some View {
        if #available(iOS 17.0, *) {
            buttonRepeatBehavior(enabled ? .enabled : .disabled)
        } else {
            self
        }
    }

    /// `buttonBorderShape(.circle)` (iOS 17); a capsule on iOS 16, which is a circle for
    /// the square buttons that use it.
    @ViewBuilder
    func compatCircleButtonBorderShape() -> some View {
        if #available(iOS 17.0, *) {
            buttonBorderShape(.circle)
        } else {
            buttonBorderShape(.capsule)
        }
    }
}

private struct LegacyContentInset: ViewModifier {
    let edges: Edge.Set
    let length: CGFloat

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { spacer(.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { spacer(.bottom) }
            .safeAreaInset(edge: .leading, spacing: 0) { spacer(.leading) }
            .safeAreaInset(edge: .trailing, spacing: 0) { spacer(.trailing) }
    }

    @ViewBuilder
    private func spacer(_ edge: Edge.Set) -> some View {
        if edges.contains(edge) {
            if edge == .top || edge == .bottom {
                Color.clear.frame(height: length)
            } else {
                Color.clear.frame(width: length)
            }
        } else {
            EmptyView()
        }
    }
}

// MARK: - Symbols

extension View {
    /// `symbolEffect(.bounce, value:)`: decorative, so nothing on iOS 16.
    @ViewBuilder
    func compatBounceSymbol<Value: Equatable>(value: Value) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    /// `contentTransition(.symbolEffect(.replace))` (or the plain `.symbolEffect`); an
    /// identity transition on iOS 16.
    @ViewBuilder
    func compatSymbolContentTransition(replace: Bool = true) -> some View {
        if #available(iOS 17.0, *) {
            if replace {
                contentTransition(.symbolEffect(.replace))
            } else {
                contentTransition(.symbolEffect)
            }
        } else {
            contentTransition(.identity)
        }
    }
}

// MARK: - Shapes

extension Shape {
    /// `shape.fill(a).stroke(b, lineWidth:)`. Chaining `stroke` after `fill` needs the
    /// iOS 17 overload; this draws the stroke as an overlay, which works everywhere.
    func compatFilledStroke<Fill: ShapeStyle, Stroke: ShapeStyle>(
        fill: Fill,
        stroke: Stroke,
        lineWidth: CGFloat = 1
    ) -> some View {
        self.fill(fill)
            .overlay(self.stroke(stroke, lineWidth: lineWidth))
    }
}

// MARK: - Accessibility

enum CompatAccessibility {
    /// VoiceOver announcement. `AccessibilityNotification.Announcement` needs iOS 17.
    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - Navigation

extension View {
    /// `navigationDestination(item:destination:)` (iOS 17), built on the iOS 16
    /// `navigationDestination(isPresented:)`.
    @ViewBuilder
    func compatNavigationDestination<Item: Hashable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17.0, *) {
            navigationDestination(item: item, destination: destination)
        } else {
            navigationDestination(
                isPresented: Binding(
                    get: { item.wrappedValue != nil },
                    set: { presented in
                        if !presented { item.wrappedValue = nil }
                    }
                )
            ) {
                if let value = item.wrappedValue {
                    destination(value)
                }
            }
        }
    }
}

// MARK: - Pinch gesture

private struct CompatMagnifyModifier: ViewModifier {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.simultaneousGesture(
                MagnifyGesture()
                    .onChanged { onChanged($0.magnification) }
                    .onEnded { onEnded($0.magnification) }
            )
        } else {
            content.simultaneousGesture(
                MagnificationGesture()
                    .onChanged { onChanged($0) }
                    .onEnded { onEnded($0) }
            )
        }
    }
}

extension View {
    /// A pinch recognised alongside other gestures; `MagnifyGesture` on iOS 17+ and
    /// `MagnificationGesture` before. Both report the scale factor.
    func compatSimultaneousMagnify(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(CompatMagnifyModifier(onChanged: onChanged, onEnded: onEnded))
    }
}
