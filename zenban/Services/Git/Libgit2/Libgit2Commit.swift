import Foundation
import Clibgit2

/// Commit operations extension for Libgit2Repository
nonisolated extension Libgit2Repository {

    /// Create a new commit
    func commit(message: String, amend: Bool = false) throws -> String {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        let index = try getIndex()
        defer { git_index_free(index) }

        if git_index_entrycount(index) == 0 && !amend {
            throw Libgit2Error.indexError("Nothing to commit")
        }

        var treeOid = git_oid()
        let writeError = git_index_write_tree(&treeOid, index)
        guard writeError == 0 else {
            throw Libgit2Error.from(writeError, context: "write tree")
        }

        var tree: OpaquePointer?
        let treeLookupError = git_tree_lookup(&tree, ptr, &treeOid)
        guard treeLookupError == 0, let t = tree else {
            throw Libgit2Error.from(treeLookupError, context: "tree lookup")
        }
        defer { git_tree_free(t) }

        let sig = try defaultSignature()
        defer { git_signature_free(sig) }

        var commitOid = git_oid()

        if amend {
            let headRef = try head()
            defer { git_reference_free(headRef) }

            var headCommit: OpaquePointer?
            let peelError = git_reference_peel(&headCommit, headRef, GIT_OBJECT_COMMIT)
            guard peelError == 0, let hc = headCommit else {
                throw Libgit2Error.from(peelError, context: "peel HEAD")
            }
            defer { git_commit_free(hc) }

            let amendError = git_commit_amend(
                &commitOid,
                hc,
                "HEAD",
                nil,
                sig,
                nil,
                message,
                t
            )
            guard amendError == 0 else {
                throw Libgit2Error.from(amendError, context: "amend commit")
            }
        } else {
            var parents: [OpaquePointer?] = []
            var parentCount = 0

            var headRef: OpaquePointer?
            if git_repository_head(&headRef, ptr) == 0, let h = headRef {
                defer { git_reference_free(h) }

                var headCommit: OpaquePointer?
                if git_reference_peel(&headCommit, h, GIT_OBJECT_COMMIT) == 0, let hc = headCommit {
                    parents.append(hc)
                    parentCount = 1
                }
            }
            defer { parents.compactMap { $0 }.forEach { git_commit_free($0) } }

            let commitError: Int32
            if parentCount > 0 {
                commitError = parents.withUnsafeMutableBufferPointer { buffer in
                    git_commit_create(
                        &commitOid,
                        ptr,
                        "HEAD",
                        sig,
                        sig,
                        nil,
                        message,
                        t,
                        1,
                        buffer.baseAddress
                    )
                }
            } else {
                commitError = git_commit_create(
                    &commitOid,
                    ptr,
                    "HEAD",
                    sig,
                    sig,
                    nil,
                    message,
                    t,
                    0,
                    nil
                )
            }

            guard commitError == 0 else {
                throw Libgit2Error.from(commitError, context: "create commit")
            }
        }

        var oidStr = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&oidStr, 41, &commitOid)
        return String(cString: oidStr)
    }

    /// Get commit summaries for a range (e.g., "main..HEAD")
    func commitSummaries(range: String, limit: Int = 50) throws -> [String] {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var revwalk: OpaquePointer?
        let walkError = git_revwalk_new(&revwalk, ptr)
        guard walkError == 0, let walk = revwalk else {
            throw Libgit2Error.from(walkError, context: "revwalk new")
        }
        defer { git_revwalk_free(walk) }

        git_revwalk_sorting(walk, UInt32(GIT_SORT_TIME.rawValue))

        let pushError = git_revwalk_push_range(walk, range)
        if pushError != 0 {
            return []
        }

        var result: [String] = []
        var oid = git_oid()

        while git_revwalk_next(&oid, walk) == 0 {
            if result.count >= limit {
                break
            }

            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, ptr, &oid) == 0, let c = commit else {
                continue
            }
            defer { git_commit_free(c) }

            let summary = git_commit_summary(c).map { String(cString: $0) } ?? ""
            if !summary.isEmpty {
                result.append(summary)
            }
        }

        return result
    }
}
