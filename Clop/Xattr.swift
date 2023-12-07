import Foundation

enum Xattr {
    /** Error type */
    struct Error: Swift.Error {
        let localizedDescription = String(utf8String: strerror(errno))
    }

    static let queue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "com.lowtechguys.Clop").xattr", attributes: .concurrent)

    static func withTimeout(_ timeout: TimeInterval, _ block: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: block)
        queue.async(execute: workItem)
        let result = workItem.wait(timeout: .now() + timeout)
        if result == .timedOut {
            log.error("Xattr timed out")
            workItem.cancel()
        }
    }
    /**
       Set extended attribute at path

       - Parameters:
         - name: Name of extended attribute
         - data: Data associated with the attribute
         - path: Path to file, directory, symlink etc
     */
    static func set(named name: String, data: Data, atPath path: String) throws {
        var error: Swift.Error?

        withTimeout(5) {
            if setxattr(path, name, (data as NSData).bytes, data.count, 0, 0) == -1 {
                error = Error()
            }
        }

        if let error {
            throw error
        }
    }

    /**
     Remove extended attribute at path

     - Parameters:
       - name: Name of extended attribute
       - path: Path to file, directory, symlink etc
     */
    static func remove(named name: String, atPath path: String) throws {
        var error: Swift.Error?

        withTimeout(5) {
            if removexattr(path, name, 0) == -1 {
                error = Error()
            }
        }

        if let error {
            throw error
        }
    }

    /**
       Get data for extended attribute at path

       - Parameters:
         - name: Name of extended attribute
         - path: Path to file, directory, symlink etc
     */
    static func dataFor(named name: String, atPath path: String) throws -> Data {
        var error: Swift.Error?
        var data: Data?

        withTimeout(5) {
            let bufLength = getxattr(path, name, nil, 0, 0, 0)

            guard bufLength != -1, let buf = malloc(bufLength), getxattr(path, name, buf, bufLength, 0, 0) != -1 else {
                error = Error()
                return
            }

            data = Data(bytes: buf, count: bufLength)
        }

        if let error {
            throw error
        }
        guard let data else {
            throw Error()
        }
        return data
    }

    /**
       Get names of extended attributes at path

       - Parameters:
         - path: Path to file, directory, symlink etc
     */
    static func names(atPath path: String) throws -> [String]? {
        var error: Swift.Error?
        var data: [String]?
        withTimeout(5) {
            let bufLength = listxattr(path, nil, 0, 0)
            guard bufLength != -1 else {
                error = Error()
                return
            }

            let buf = UnsafeMutablePointer<Int8>.allocate(capacity: bufLength)
            guard listxattr(path, buf, bufLength, 0) != -1 else {
                error = Error()
                return
            }

            var names = NSString(bytes: buf, length: bufLength, encoding: String.Encoding.utf8.rawValue)?.components(separatedBy: "\0")
            names?.removeLast()
            data = names
        }

        if let error {
            throw error
        }
        guard let data else {
            throw Error()
        }
        return data
    }
}
