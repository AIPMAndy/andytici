//
//  QRCodeCache.swift
//  Textream
//
//  Shared URL-keyed QR code generator cache.
//

import AppKit
import CoreImage

/// URL-keyed QR code image cache. Same body-cache pattern as R77-R83 but
/// for NSImage outputs instead of String/Double.
///
/// The QR generation pipeline is non-trivial: it spins up a new `CIContext`
/// (Metal-backed on Apple Silicon), runs the QR matrix algorithm via
/// `CIFilter.qrCodeGenerator()`, scales the matrix 10×, and renders to a
/// `CGImage` via `createCGImage`. The total cost is ~5-15 ms per call,
/// almost all of which is the CGImage render.
///
/// There are three call sites that all run this pipeline for the same kind
/// of input (a `http://<ip>:<port>` URL string):
///
/// - `ContentView.directorOverlay` (line 493) — body re-renders on every
///   parent state change, even when the URL hasn't changed.
/// - `SettingsView.browserTab` (line 1124) — body re-renders on every
///   keystroke in the port TextField that produces a valid UInt16, so
///   typing `8080` triggers 4 QR regenerations per tab.
/// - `SettingsView.directorTab` (line 1238) — same as browserTab.
///
/// The QR output only changes when the URL changes (i.e. when the local
/// IP or port changes), so caching on the URL string is exact: every hit
/// returns the same image, every miss regenerates exactly once. URL
/// strings are short (~30 bytes), so the cache key comparison is a
/// constant-time String != String.
struct QRCodeCache {
    private var cachedURL: String = ""
    private var cachedImage: NSImage?

    mutating func image(for url: String) -> NSImage? {
        if url != cachedURL {
            cachedURL = url
            cachedImage = Self.generate(from: url)
        }
        return cachedImage
    }

    private static func generate(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}