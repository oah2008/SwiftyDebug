//
//  NetworkConditionerPreset.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Fixed network-link-conditioner presets, named to match Apple's
/// "Network Link Conditioner" profiles (Developer settings on device /
/// the macOS Additional Tools). Only *latency* is simulated — a fixed delay is
/// added before each captured request is sent, so you can observe loader /
/// spinner / skeleton states. Off by default.
///
/// Latency values below are the profile's downlink+uplink round-trip delay
/// summed into a single per-request delay (seconds), matching the Apple
/// profile numbers.
enum NetworkConditionerPreset: String, CaseIterable {
    case off = "off"
    case wifi = "wifi"
    case dsl = "dsl"
    case lte = "lte"
    case threeG = "3g"
    case edge = "edge"
    case highLatencyDNS = "highLatencyDNS"
    case veryBadNetwork = "veryBadNetwork"
    case hundredPercentLoss = "100PercentLoss"

    /// Human-readable name shown in the Info tab, matching Apple's profile names.
    var displayName: String {
        switch self {
        case .off:                 return "Off"
        case .wifi:                return "Wi-Fi"
        case .dsl:                 return "DSL"
        case .lte:                 return "LTE"
        case .threeG:              return "3G"
        case .edge:                return "Edge"
        case .highLatencyDNS:      return "High Latency DNS"
        case .veryBadNetwork:      return "Very Bad Network"
        case .hundredPercentLoss:  return "100% Loss"
        }
    }

    /// Short subtitle describing the added delay.
    var subtitle: String {
        switch self {
        case .off:                return "No added delay"
        case .hundredPercentLoss: return "All requests fail"
        default:
            let ms = Int((addedLatency * 1000).rounded())
            return "≈ \(ms) ms added latency"
        }
    }

    /// Fixed added latency (seconds) applied before the request is sent.
    /// Values approximate Apple's Network Link Conditioner round-trip delays.
    var addedLatency: TimeInterval {
        switch self {
        case .off:                return 0
        case .wifi:               return 0.001   // ~1 ms
        case .dsl:                return 0.010   // ~10 ms
        case .lte:                return 0.050   // ~50 ms
        case .threeG:             return 0.100   // ~100 ms
        case .edge:               return 0.400   // ~400 ms
        case .highLatencyDNS:     return 0.220   // Apple "High Latency DNS": ~220 ms
        case .veryBadNetwork:     return 0.500   // ~500 ms
        case .hundredPercentLoss: return 0       // handled specially: fail, no delay
        }
    }

    /// When `true`, the request should be failed outright (100% packet loss)
    /// rather than merely delayed.
    var dropsAllRequests: Bool {
        self == .hundredPercentLoss
    }

    /// Whether the preset has any runtime effect.
    var isActive: Bool {
        self != .off
    }
}
