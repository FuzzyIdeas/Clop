import Atomics
import Foundation

/// Counter of in-flight CLI requests. Used to suppress hang-detection
/// auto-restart while a long-running CLI invocation is being processed.
let activeCLIRequests = ManagedAtomic<Int>(0)
