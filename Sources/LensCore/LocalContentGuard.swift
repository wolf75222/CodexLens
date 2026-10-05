import Foundation
import Darwin

/// Never trigger automatic hydration of a known cloud placeholder during a
/// read-only inspection. A path remains a reference while its bytes are absent.
enum LocalContentGuard {
    static func requireResident(path: String, flags: UInt32) throws {
        guard flags & UInt32(SF_DATALESS) == 0 else { throw LensError.unavailable("Ce fichier n’est pas téléchargé sur ce Mac : \(path). Téléchargez-le dans le Finder, puis ouvrez-le à nouveau dans Lens.") }
    }
    static func requireResident(path: String) throws {
        var metadata = stat()
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard resolved.withCString({ lstat($0, &metadata) }) == 0 else { throw LensError.unavailable("Fichier local inaccessible : \(path)") }
        try requireResident(path: path, flags: metadata.st_flags)
    }
}
