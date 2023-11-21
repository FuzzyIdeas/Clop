import Defaults
import Foundation
import Lowtech

enum Migrations {
    static func run() {
        clopIgnoreMigrate()
    }

    static func clopIgnoreMigrate() {
        for fileType in ClopFileType.allCases {
            let key = Defaults.Key<[String]?>("\(fileType.rawValue)Dirs")
            for dir in Defaults[key]?.compactMap(\.existingFilePath) ?? [] {
                let clopIgnore = dir / ".clopignore"
                guard clopIgnore.exists else {
                    continue
                }

                for otherFileType in fileType.otherCases {
                    let key = Defaults.Key<[String]?>("\(otherFileType.rawValue)Dirs")
                    guard let dirs = Defaults[key], dirs.contains(dir.string) else {
                        continue
                    }
                    let newClopIgnore = dir / ".clopignore-\(otherFileType.rawValue)"
                    _ = try? clopIgnore.copy(to: newClopIgnore)
                }

                let newClopIgnore = dir / ".clopignore-\(fileType.rawValue)"
                if newClopIgnore.exists {
                    try? clopIgnore.delete()
                } else {
                    _ = try? clopIgnore.move(to: newClopIgnore)
                }
            }
        }
    }
}
