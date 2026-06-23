//
//  PrivacyBlindsMath.swift
//  PrivacyBlinds
//
//  Small numeric helpers shared across the package (and unit-tested directly).
//

import Foundation

@inline(__always)
func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let denom = max(edge1 - edge0, .leastNonzeroMagnitude)
    let t = max(0, min(1, (x - edge0) / denom))
    return t * t * (3 - 2 * t)
}

@inline(__always)
func wrapToPi(_ angle: Float) -> Float {
    var x = angle
    while x > .pi { x -= 2 * .pi }
    while x < -.pi { x += 2 * .pi }
    return x
}
