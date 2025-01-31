//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Just a container for simple static helper methods on KeyBackupServiceImpl
/// that can be shared with other classes (incl. objc classes).
@objc
public final class SecureValueRecoveryObjcBridge: NSObject {

    private override init() {}

    @objc
    public static var hasBackedUpMasterKey: Bool {
        DependenciesBridge.shared.svr.hasBackedUpMasterKey
    }

    @objc
    public static func deriveRegistrationLockToken() -> String? {
        return DependenciesBridge.shared.svr.deriveRegistrationLockToken()
    }
}
