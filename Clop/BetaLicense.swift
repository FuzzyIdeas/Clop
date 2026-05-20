import Foundation
import Lowtech
import LowtechPro
import os

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "BetaLicense")

let BETA_LICENSE_KEY = "19EA003C-9733E303-9245109D-CC00C6CA-AD0422C4"

@MainActor
enum BetaLicenseChecker {
    /// Starts daily Paddle re-verification for the beta license.
    ///
    /// Paddle normally only re-verifies activated licenses every 7 days, but beta licenses have
    /// a fixed expiry date and we want machines to pick up the revocation on the day it happens,
    /// not a week later. This only forces verification when the currently-active license code
    /// matches the beta key, so regular users are unaffected.
    static func start() {
        dailyCheckTimer?.invalidate()
        forceVerifyIfBeta()
        dailyCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            Task { @MainActor in forceVerifyIfBeta() }
        }
    }

    private static var dailyCheckTimer: Timer?

    private static func forceVerifyIfBeta() {
        guard let code = product?.licenseCode,
              code.caseInsensitiveCompare(BETA_LICENSE_KEY) == .orderedSame
        else { return }

        log.debug("Beta license detected; forcing Paddle re-verification")
        PM.pro?.verifyLicense(force: true)
    }
}
