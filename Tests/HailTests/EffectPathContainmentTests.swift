import Hail
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Regression coverage for the symlink-then-".." escape: a lexical ".."
/// collapse treats `link/..` as cancelling `link` back to nothing, which is
/// only true when `link` is a real directory. When it is a symlink,
/// `link/..` really means "the parent of wherever `link` points" — anywhere,
/// including outside an allowed root — and a containment check built on the
/// lexical collapse cannot see that, because the collapse already discarded
/// the fact that `link` was traversed before the check ever runs.
@Suite("EffectPath containment")
struct EffectPathContainmentTests {
    private func makeWorkspace() throws -> (root: String, outside: String, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-effectpath-\(UUID().uuidString)")
        let root = base.appendingPathComponent("workspace")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (root.path, outside.path, { try? FileManager.default.removeItem(at: base) })
    }

    @Test("an ordinary path inside the root is contained")
    func ordinaryPathIsContained() throws {
        let (root, _, cleanup) = try makeWorkspace()
        defer { cleanup() }
        #expect(EffectPath.isContained("\(root)/notes.txt", in: root))
    }

    @Test("a path that lexically escapes the root is not contained")
    func lexicalEscapeIsDenied() throws {
        let (root, _, cleanup) = try makeWorkspace()
        defer { cleanup() }
        #expect(!EffectPath.isContained("\(root)/../../etc/passwd", in: root))
    }

    @Test("a symlink pointing directly outside the root is not contained")
    func directSymlinkEscapeIsDenied() throws {
        let (root, outside, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let link = "\(root)/out"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        #expect(!EffectPath.isContained("\(link)/secret.txt", in: root))
    }

    @Test("\"..\" through a symlink resolves against the real target, not the written text")
    func symlinkThenDotDotEscapeIsDenied() throws {
        let (root, outside, cleanup) = try makeWorkspace()
        defer { cleanup() }
        // `outside` is a sibling of `root`, one level below their shared
        // parent, so a single ".." after the symlink is enough to leave
        // `outside` (landing at their shared parent) without also leaving
        // `root` lexically — that gap is exactly what a naive lexical
        // collapse of "link/.." (cancelling to nothing) would miss.
        let link = "\(root)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let attack = "\(root)/link/../\((outside as NSString).lastPathComponent)-sibling.txt"
        #expect(!EffectPath.isContained(attack, in: root))
    }

    @Test("a write target that does not exist yet is still contained when its parent is real")
    func nonexistentWriteTargetIsContained() throws {
        let (root, _, cleanup) = try makeWorkspace()
        defer { cleanup() }
        #expect(EffectPath.isContained("\(root)/new/nested/file.txt", in: root))
    }

    @Test("a write target behind a symlinked directory is not contained")
    func writeThroughSymlinkedDirectoryIsDenied() throws {
        let (root, outside, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let link = "\(root)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        #expect(!EffectPath.isContained("\(link)/not-yet-created.txt", in: root))
    }

    @Test("a backslash is a filename character, not a separator")
    func backslashIsNotASeparator() throws {
        let (root, outside, cleanup) = try makeWorkspace()
        defer { cleanup() }
        // `a/b` is a real directory inside the root; `a\b` is a symlink out.
        // Treating "\" as "/" would check the first and open the second.
        try FileManager.default.createDirectory(
            atPath: "\(root)/a/b",
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: "\(root)/a\\b", withDestinationPath: outside)
        #expect(!EffectPath.isContained("\(root)/a\\b/secret", in: root))
        #expect(EffectPath.isContained("\(root)/a/b/secret", in: root))
    }

    @Test("FileEffect.pathPolicy denies the symlink-then-\"..\" escape")
    func filePathPolicyDeniesSymlinkEscape() throws {
        let (root, outside, cleanup) = try makeWorkspace()
        defer { cleanup() }
        let link = "\(root)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        let attack = "\(root)/link/../\((outside as NSString).lastPathComponent)-sibling.txt"
        let policy = FileEffect.pathPolicy(scopedTo: root)
        let decision = policy(FileEffect(path: attack, action: .read))
        guard case .denied = decision else {
            Issue.record("Expected the symlink escape to be denied, got \(decision)")
            return
        }
    }
}
