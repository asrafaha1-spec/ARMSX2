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
@MainActor
@propertyWrapper
struct ObservedOptional<Object: ObservableObject>: DynamicProperty {
    @StateObject private var relay = ObservedOptionalRelay()
    private let object: Object?

    init(wrappedValue: Object?) {
        object = wrappedValue
    }

    var wrappedValue: Object? { object }

    func update() {
        relay.attach(to: object)
    }
}

@MainActor
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
private struct LegacyOnChange<Value: Equatable>: ViewModifier {
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

    func body(content: Content) -> some View {
        content
            .onAppear {
                // `initial: true` fires once, when the view first appears, with old
                // and new equal - the same as the iOS 17 behaviour.
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

extension View {
    /// `onChange(of:initial:_:)` with the iOS 17 signature, usable from iOS 16.
    @ViewBuilder
    func compatOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(LegacyOnChange(value: value, initial: initial, action: action))
        }
    }

    /// The no-argument form of `onChange(of:initial:_:)`.
    func compatOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        compatOnChange(of: value, initial: initial) { _, _ in action() }
    }
}
