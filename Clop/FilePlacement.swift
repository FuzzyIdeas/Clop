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
///
/// Idempotent: a `path` that already sits at the templated location is returned unchanged. The
/// drop zone and file watchers copy the original to the templated destination BEFORE optimising
/// (so the original survives untouched) and the pipeline places its output from that copy's path;
/// templating it again would stack suffixes (`img-optim.png` -> `img-optim-optim.png`).
func destinationPath(type: ClopFileType, kind: OutputKind, path: FilePath, overrides: PlacementOverride?) throws -> FilePath? {
    switch effectiveBehaviour(type: type, kind: kind, overrides: overrides) {
    case .temporary:
        return nil
    case .inPlace:
        return path
    case .sameFolder:
        let template = overrides?.sameFolderTemplate ?? type.sameFolderTemplateKey(for: kind).map { Defaults[$0] } ?? "%f"
        if nameMatchesTemplate(path.stem ?? path.name.string, template: template) {
            return path
        }
        return path.dir / generateFileName(template: template, for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber])
    case .specificFolder:
        let template = overrides?.specificFolderTemplate ?? type.specificFolderTemplateKey(for: kind).map { Defaults[$0] } ?? "%P/optimised/%f"
        let pathWithoutExtension = (path.dir / (path.stem ?? path.name.string)).string
        let isAbsoluteTemplate = template.hasPrefix("/") || template.hasPrefix("%P") || template.hasPrefix("%F")
        if nameMatchesTemplate(pathWithoutExtension, template: template, allowPathPrefix: !isAbsoluteTemplate) {
            return path
        }
        return try generateFilePath(template: template, for: path, autoIncrementingNumber: &Defaults[.lastAutoIncrementingNumber], mkdir: true)
    }
}

/// Cheap, decision-only step: resolve the behaviour and destination path (including the auto-increment
/// naming counter). Carries no heavy file I/O, so it is safe to run on the main actor to keep the
/// counter serialized. Pair with `executePlacement` which does the actual move/copy off the main thread.
struct PlacementPlan {
    let behaviour: FileBehaviour
    /// nil means "leave `produced` where it is, original untouched" (temporary or no destination).
    let dest: FilePath?
}

func planPlacement(produced: FilePath, original: FilePath, type: ClopFileType, kind: OutputKind, overrides: PlacementOverride? = nil) throws -> PlacementPlan {
    let behaviour = effectiveBehaviour(type: type, kind: kind, overrides: overrides)
    guard behaviour != .temporary else {
        return PlacementPlan(behaviour: behaviour, dest: nil)
    }
    guard var dest = try destinationPath(type: type, kind: kind, path: original, overrides: overrides) else {
        return PlacementPlan(behaviour: behaviour, dest: nil)
    }
    // For inPlace and sameFolder the destination is derived from the original (which keeps the
    // original extension); apply the produced file's extension so conversions land as e.g. .webp.
    let producedExt = produced.extension ?? original.extension ?? ""
    if dest.extension?.lowercased() != producedExt.lowercased() {
        dest = dest.withExtension(producedExt)
    }
    return PlacementPlan(behaviour: behaviour, dest: dest)
}

/// Heavy file I/O: backup move + copy to the destination. For large or cross-volume files this can
/// take tens of seconds, so it MUST run OFF the main thread (it blocked the main thread for 30s+ on
/// big videos — CLOP-277, CLOP-1A7). Never call this under `DispatchQueue.main.sync`.
func executePlacement(_ plan: PlacementPlan, produced: FilePath, original: FilePath) throws -> PlacedOutput {
    guard let dest = plan.dest else {
        return PlacedOutput(path: produced, backup: nil, originalRemoved: false)
    }
    var backup: FilePath?
    var originalRemoved = false
    if plan.behaviour == .inPlace, original.exists, let backupPath = original.clopBackupPath {
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

/// Place a freshly-produced temp file (`produced`) according to the behaviour for `(type, kind)`.
/// - temporary: leave `produced` where it is, original untouched.
/// - inPlace: move the original into the backup cache, then put `produced` at the original's
///   location (with `produced`'s extension, so a conversion replaces the original).
/// - sameFolder / specificFolder: write `produced` to the templated destination, original kept.
@MainActor func placeOutput(produced: FilePath, original: FilePath, type: ClopFileType, kind: OutputKind, overrides: PlacementOverride? = nil) throws -> PlacedOutput {
    let plan = try planPlacement(produced: produced, original: original, type: type, kind: kind, overrides: overrides)
    return try executePlacement(plan, produced: produced, original: original)
}
