import Defaults
import Foundation
import Lowtech
import os
import System

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "FilePlacement")

struct PlacedOutput {
    let path: FilePath
    let backup: FilePath?
    let originalRemoved: Bool
}

/// Resolve the effective behaviour for `(type, kind)`, honouring a per-request override.
/// Optimise always has a behaviour; conversions fall back to the optimise behaviour for PDF
/// (which has no conversion keys) so callers never crash on a nil key.
func effectiveBehaviour(type: ClopFileType, kind: OutputKind, overrides: PlacementOverride?) -> FileBehaviour {
    if let o = overrides?.behaviour(for: kind) { return o }
    if let key = type.behaviourKey(for: kind) { return Defaults[key] }
    return Defaults[type.optimisedBehaviourKey]
}

/// Compute the destination path for a produced file. Returns nil for `.temporary` (leave in place)
/// or when no template/key applies. `path` is the ORIGINAL source path (used for the dir + templates);
/// the produced file's extension is applied by the caller via `produced`.
func destinationPath(type: ClopFileType, kind: OutputKind, path: FilePath, overrides: PlacementOverride?) throws -> FilePath? {
    switch effectiveBehaviour(type: type, kind: kind, overrides: overrides) {
    case .temporary:
        return nil
    case .inPlace:
        return path
    case .sameFolder:
        let template = overrides?.sameFolderTemplate ?? type.sameFolderTemplateKey(for: kind).map { Defaults[$0] } ?? "%f"
        return path.dir / generateFileName(template: template, for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber])
    case .specificFolder:
        let template = overrides?.specificFolderTemplate ?? type.specificFolderTemplateKey(for: kind).map { Defaults[$0] } ?? "%P/optimised/%f"
        return try generateFilePath(template: template, for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber], mkdir: true)
    }
}

/// Place a freshly-produced temp file (`produced`) according to the behaviour for `(type, kind)`.
/// - temporary: leave `produced` where it is, original untouched.
/// - inPlace: move the original into the backup cache, then put `produced` at the original's
///   location (with `produced`'s extension, so a conversion replaces the original).
/// - sameFolder / specificFolder: write `produced` to the templated destination, original kept.
@MainActor func placeOutput(produced: FilePath, original: FilePath, type: ClopFileType, kind: OutputKind, overrides: PlacementOverride? = nil) throws -> PlacedOutput {
    let behaviour = effectiveBehaviour(type: type, kind: kind, overrides: overrides)
    let producedExt = produced.extension ?? original.extension ?? ""

    guard behaviour != .temporary else {
        return PlacedOutput(path: produced, backup: nil, originalRemoved: false)
    }
    guard var dest = try destinationPath(type: type, kind: kind, path: original, overrides: overrides) else {
        return PlacedOutput(path: produced, backup: nil, originalRemoved: false)
    }
    // For inPlace and sameFolder the destination is derived from the original (which keeps the
    // original extension); apply the produced file's extension so conversions land as e.g. .webp.
    if dest.extension?.lowercased() != producedExt.lowercased() {
        dest = dest.withExtension(producedExt)
    }

    var backup: FilePath?
    var originalRemoved = false
    if behaviour == .inPlace, original.exists, let backupPath = original.clopBackupPath {
        if original == produced {
            // The optimiser worked in place, so `produced` IS the original and already sits at the
            // destination. Moving it into the backup cache here would orphan the destination (the copy
            // below would then be a no-op self-copy), leaving the result pointing at a file that no
            // longer exists. Keep the file where it is and surface the pre-optimise backup taken earlier.
            backup = backupPath.exists ? backupPath : nil
        } else if let moved = original.backup(path: backupPath, force: true, operation: .move) {
            backup = moved
            originalRemoved = true
        } else {
            log.error("Backup move failed for \(original.string); leaving original in place")
        }
        // A pure same-format optimise overwrites the original at `dest == original`; the move above
        // already cleared it. A conversion writes a new-extension file and the original is now gone.
    }

    // Skip a redundant self-copy (and its "copy path to itself" error) when the produced file already
    // sits at the destination, e.g. an in-place optimise where produced == original == dest.
    let finalPath = produced == dest ? produced : try produced.copy(to: dest, force: true)
    try? finalPath.setOptimisationStatusXattr("true")
    return PlacedOutput(path: finalPath, backup: backup, originalRemoved: originalRemoved)
}
