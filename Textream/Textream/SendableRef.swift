//
//  SendableRef.swift
//  Andy题词
//
//  Helper for Observation-tracking closures (R110).
//

import Foundation

/// A Sendable wrapper around a non-Sendable reference.
///
/// `withObservationTracking { … } onChange: { … }` requires its
/// `onChange` closure to be `@Sendable`, so only Sendable values
/// can be carried out. Observation flags like
/// `SpeechRecognizer.shouldDismiss` live on non-Sendable classes,
/// so we cannot capture them directly — the compiler rejects the
/// capture as a `SendableClosureCaptures` warning.
///
/// `UnsafeSendableRef` is declared `@unchecked Sendable`: the
/// caller takes responsibility that accesses through `.value`
/// happen on a thread that is safe for the wrapped reference.
/// In this codebase the inner work is always handed off to a
/// `DispatchQueue.main.async` block, so every `.value` access
/// runs on the main thread. This matches the original
/// pre-wrapper semantics, just without the compiler warnings.
final class UnsafeSendableRef<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}