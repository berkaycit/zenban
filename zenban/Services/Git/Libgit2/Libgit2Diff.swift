import Foundation
import Clibgit2

/// Line change type in diff
nonisolated enum Libgit2LineOrigin: Character, Sendable {
    case context = " "
    case addition = "+"
    case deletion = "-"
    case contextEofnl = "="
    case addEofnl = ">"
    case delEofnl = "<"
    case fileHeader = "F"
    case hunkHeader = "H"
    case binary = "B"

    init(from origin: CChar) {
        switch origin {
        case 32: self = .context        // ' '
        case 43: self = .addition       // '+'
        case 45: self = .deletion       // '-'
        case 61: self = .contextEofnl   // '='
        case 62: self = .addEofnl       // '>'
        case 60: self = .delEofnl       // '<'
        case 70: self = .fileHeader     // 'F'
        case 72: self = .hunkHeader     // 'H'
        case 66: self = .binary         // 'B'
        default: self = .context
        }
    }
}

/// A single line in a diff
nonisolated struct Libgit2DiffLine: Sendable {
    let origin: Libgit2LineOrigin
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
}

/// A hunk in a diff
nonisolated struct Libgit2DiffHunk: Sendable {
    let header: String
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [Libgit2DiffLine]
}

/// Diff delta (file change)
nonisolated struct Libgit2DiffDelta: Sendable {
    let oldPath: String?
    let newPath: String?
    let status: DeltaStatus
    let hunks: [Libgit2DiffHunk]
    let additions: Int
    let deletions: Int
    let isBinary: Bool

    enum DeltaStatus: Sendable {
        case unmodified
        case added
        case deleted
        case modified
        case renamed
        case copied
        case ignored
        case untracked
        case typeChange
        case unreadable
        case conflicted
    }
}

/// Diff statistics
nonisolated struct Libgit2DiffStats: Sendable {
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
}

/// Diff operations extension for Libgit2Repository
nonisolated extension Libgit2Repository {

    /// Get diff between HEAD and workdir (combined staged + unstaged)
    func diffHeadToWorkdir(includeUntracked: Bool = true) throws -> [Libgit2DiffDelta] {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var tree: OpaquePointer? = nil
        var head: OpaquePointer?
        if git_repository_head(&head, ptr) == 0, let h = head {
            defer { git_reference_free(h) }
            var commit: OpaquePointer?
            if git_reference_peel(&commit, h, GIT_OBJECT_COMMIT) == 0, let c = commit {
                defer { git_commit_free(c) }
                var t: OpaquePointer?
                if git_commit_tree(&t, c) == 0 {
                    tree = t
                }
            }
        }
        defer { if let t = tree { git_tree_free(t) } }

        var diff: OpaquePointer?
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        if includeUntracked {
            opts.flags = UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue)
        }

        let diffError = git_diff_tree_to_workdir_with_index(&diff, ptr, tree, &opts)
        guard diffError == 0, let d = diff else {
            throw Libgit2Error.from(diffError, context: "diff tree to workdir")
        }
        defer { git_diff_free(d) }

        return try parseDiff(d)
    }

    // MARK: - Private Helpers

    private func parseDiff(_ diff: OpaquePointer) throws -> [Libgit2DiffDelta] {
        var deltas: [Libgit2DiffDelta] = []

        let numDeltas = git_diff_num_deltas(diff)
        for i in 0..<numDeltas {
            guard let delta = git_diff_get_delta(diff, i) else { continue }

            let status = parseDeltaStatus(delta.pointee.status)
            let oldPath = delta.pointee.old_file.path.map { String(cString: $0) }
            let newPath = delta.pointee.new_file.path.map { String(cString: $0) }
            let isBinary = (delta.pointee.flags & UInt32(GIT_DIFF_FLAG_BINARY.rawValue)) != 0

            // Get hunks and lines
            var hunks: [Libgit2DiffHunk] = []
            var additions = 0
            var deletions = 0

            // Use patch to get detailed line info
            var patch: OpaquePointer?
            if git_patch_from_diff(&patch, diff, i) == 0, let p = patch {
                defer { git_patch_free(p) }

                let numHunks = git_patch_num_hunks(p)
                for h in 0..<numHunks {
                    var hunk: UnsafePointer<git_diff_hunk>?
                    var hunkLines: Int = 0

                    guard git_patch_get_hunk(&hunk, &hunkLines, p, h) == 0, let hunkPtr = hunk else {
                        continue
                    }

                    var lines: [Libgit2DiffLine] = []
                    for l in 0..<hunkLines {
                        var line: UnsafePointer<git_diff_line>?
                        guard git_patch_get_line_in_hunk(&line, p, h, l) == 0, let linePtr = line else {
                            continue
                        }

                        let origin = Libgit2LineOrigin(from: linePtr.pointee.origin)
                        let content: String
                        if let contentPtr = linePtr.pointee.content {
                            let buffer = UnsafeRawBufferPointer(
                                start: contentPtr,
                                count: linePtr.pointee.content_len
                            )
                            content = String(decoding: buffer, as: UTF8.self)
                        } else {
                            content = ""
                        }

                        let oldLine = linePtr.pointee.old_lineno > 0 ? Int(linePtr.pointee.old_lineno) : nil
                        let newLine = linePtr.pointee.new_lineno > 0 ? Int(linePtr.pointee.new_lineno) : nil

                        lines.append(Libgit2DiffLine(
                            origin: origin,
                            oldLineNumber: oldLine,
                            newLineNumber: newLine,
                            content: content
                        ))

                        if origin == .addition { additions += 1 }
                        if origin == .deletion { deletions += 1 }
                    }

                    let header = withUnsafePointer(to: hunkPtr.pointee.header) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(GIT_DIFF_HUNK_HEADER_SIZE)) {
                            String(cString: $0)
                        }
                    }
                    hunks.append(Libgit2DiffHunk(
                        header: header,
                        oldStart: Int(hunkPtr.pointee.old_start),
                        oldLines: Int(hunkPtr.pointee.old_lines),
                        newStart: Int(hunkPtr.pointee.new_start),
                        newLines: Int(hunkPtr.pointee.new_lines),
                        lines: lines
                    ))
                }
            }

            deltas.append(Libgit2DiffDelta(
                oldPath: oldPath,
                newPath: newPath,
                status: status,
                hunks: hunks,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary
            ))
        }

        return deltas
    }

    private func parseDeltaStatus(_ status: git_delta_t) -> Libgit2DiffDelta.DeltaStatus {
        switch status {
        case GIT_DELTA_UNMODIFIED: return .unmodified
        case GIT_DELTA_ADDED: return .added
        case GIT_DELTA_DELETED: return .deleted
        case GIT_DELTA_MODIFIED: return .modified
        case GIT_DELTA_RENAMED: return .renamed
        case GIT_DELTA_COPIED: return .copied
        case GIT_DELTA_IGNORED: return .ignored
        case GIT_DELTA_UNTRACKED: return .untracked
        case GIT_DELTA_TYPECHANGE: return .typeChange
        case GIT_DELTA_UNREADABLE: return .unreadable
        case GIT_DELTA_CONFLICTED: return .conflicted
        default: return .unmodified
        }
    }

    /// Get unified diff string for HEAD (staged + unstaged changes)
    func diffUnified(pathspec: String? = nil) throws -> String {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var result = ""

        // Get HEAD tree (if exists)
        var tree: OpaquePointer? = nil
        var head: OpaquePointer?
        if git_repository_head(&head, ptr) == 0, let h = head {
            defer { git_reference_free(h) }
            var commit: OpaquePointer?
            if git_reference_peel(&commit, h, GIT_OBJECT_COMMIT) == 0, let c = commit {
                defer { git_commit_free(c) }
                var t: OpaquePointer?
                if git_commit_tree(&t, c) == 0 {
                    tree = t
                }
            }
        }
        defer { if let t = tree { git_tree_free(t) } }

        // Diff HEAD to workdir (combined staged + unstaged)
        var diff: OpaquePointer?
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.flags = UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue)
        opts.context_lines = 3

        var pathspecArray = git_strarray()
        var pathspecStrings: [UnsafeMutablePointer<CChar>?] = []
        if let pathspec {
            pathspecStrings = [strdup(pathspec)]
            pathspecStrings.withUnsafeMutableBufferPointer { buffer in
                pathspecArray.strings = buffer.baseAddress
                pathspecArray.count = 1
            }
            opts.pathspec = pathspecArray
        }
        defer { pathspecStrings.forEach { free($0) } }

        let diffError = git_diff_tree_to_workdir_with_index(&diff, ptr, tree, &opts)
        guard diffError == 0, let d = diff else {
            throw Libgit2Error.from(diffError, context: "diff tree to workdir")
        }
        defer { git_diff_free(d) }

        result = formatDiffAsUnified(d)
        return result
    }

    /// Get unified diff string for unstaged changes only
    func diffUnstagedUnified(pathspec: String? = nil) throws -> String {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var diff: OpaquePointer?
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.flags = UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue)
        opts.context_lines = 3

        var pathspecArray = git_strarray()
        var pathspecStrings: [UnsafeMutablePointer<CChar>?] = []
        if let pathspec {
            pathspecStrings = [strdup(pathspec)]
            pathspecStrings.withUnsafeMutableBufferPointer { buffer in
                pathspecArray.strings = buffer.baseAddress
                pathspecArray.count = 1
            }
            opts.pathspec = pathspecArray
        }
        defer { pathspecStrings.forEach { free($0) } }

        let diffError = git_diff_index_to_workdir(&diff, ptr, nil, &opts)
        guard diffError == 0, let d = diff else {
            throw Libgit2Error.from(diffError, context: "diff index to workdir")
        }
        defer { git_diff_free(d) }

        return formatDiffAsUnified(d)
    }

    /// Get diff deltas for a range (merge base -> head)
    func diffBetween(base: String, head: String, pathspec: String? = nil) throws -> [Libgit2DiffDelta] {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var (baseCommit, baseOid) = try resolveCommit(base)
        defer { git_commit_free(baseCommit) }

        var (headCommit, headOid) = try resolveCommit(head)
        defer { git_commit_free(headCommit) }

        var mergeBaseOid = git_oid()
        let mergeError = git_merge_base(&mergeBaseOid, ptr, &baseOid, &headOid)
        if mergeError != 0 {
            mergeBaseOid = baseOid
        }

        var mergeCommit: OpaquePointer?
        let mergeLookupError = git_commit_lookup(&mergeCommit, ptr, &mergeBaseOid)
        guard mergeLookupError == 0, let mb = mergeCommit else {
            throw Libgit2Error.from(mergeLookupError, context: "merge base lookup")
        }
        defer { git_commit_free(mb) }

        var baseTree: OpaquePointer?
        let baseTreeError = git_commit_tree(&baseTree, mb)
        guard baseTreeError == 0, let bt = baseTree else {
            throw Libgit2Error.from(baseTreeError, context: "base tree")
        }
        defer { git_tree_free(bt) }

        var headTree: OpaquePointer?
        let headTreeError = git_commit_tree(&headTree, headCommit)
        guard headTreeError == 0, let ht = headTree else {
            throw Libgit2Error.from(headTreeError, context: "head tree")
        }
        defer { git_tree_free(ht) }

        var diff: OpaquePointer?
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))

        var pathspecArray = git_strarray()
        var pathspecStrings: [UnsafeMutablePointer<CChar>?] = []
        if let pathspec {
            pathspecStrings = [strdup(pathspec)]
            pathspecStrings.withUnsafeMutableBufferPointer { buffer in
                pathspecArray.strings = buffer.baseAddress
                pathspecArray.count = 1
            }
            opts.pathspec = pathspecArray
        }
        defer { pathspecStrings.forEach { free($0) } }

        let diffError = git_diff_tree_to_tree(&diff, ptr, bt, ht, &opts)
        guard diffError == 0, let d = diff else {
            throw Libgit2Error.from(diffError, context: "diff tree to tree")
        }
        defer { git_diff_free(d) }

        return try parseDiff(d)
    }

    /// Get unified diff string for a range (merge base -> head)
    func diffBetweenUnified(base: String, head: String, pathspec: String? = nil) throws -> String {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var (baseCommit, baseOid) = try resolveCommit(base)
        defer { git_commit_free(baseCommit) }

        var (headCommit, headOid) = try resolveCommit(head)
        defer { git_commit_free(headCommit) }

        var mergeBaseOid = git_oid()
        let mergeError = git_merge_base(&mergeBaseOid, ptr, &baseOid, &headOid)
        if mergeError != 0 {
            mergeBaseOid = baseOid
        }

        var mergeCommit: OpaquePointer?
        let mergeLookupError = git_commit_lookup(&mergeCommit, ptr, &mergeBaseOid)
        guard mergeLookupError == 0, let mb = mergeCommit else {
            throw Libgit2Error.from(mergeLookupError, context: "merge base lookup")
        }
        defer { git_commit_free(mb) }

        var baseTree: OpaquePointer?
        let baseTreeError = git_commit_tree(&baseTree, mb)
        guard baseTreeError == 0, let bt = baseTree else {
            throw Libgit2Error.from(baseTreeError, context: "base tree")
        }
        defer { git_tree_free(bt) }

        var headTree: OpaquePointer?
        let headTreeError = git_commit_tree(&headTree, headCommit)
        guard headTreeError == 0, let ht = headTree else {
            throw Libgit2Error.from(headTreeError, context: "head tree")
        }
        defer { git_tree_free(ht) }

        var diff: OpaquePointer?
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.context_lines = 3

        var pathspecArray = git_strarray()
        var pathspecStrings: [UnsafeMutablePointer<CChar>?] = []
        if let pathspec {
            pathspecStrings = [strdup(pathspec)]
            pathspecStrings.withUnsafeMutableBufferPointer { buffer in
                pathspecArray.strings = buffer.baseAddress
                pathspecArray.count = 1
            }
            opts.pathspec = pathspecArray
        }
        defer { pathspecStrings.forEach { free($0) } }

        let diffError = git_diff_tree_to_tree(&diff, ptr, bt, ht, &opts)
        guard diffError == 0, let d = diff else {
            throw Libgit2Error.from(diffError, context: "diff tree to tree")
        }
        defer { git_diff_free(d) }

        return formatDiffAsUnified(d)
    }

    private func resolveCommit(_ ref: String) throws -> (OpaquePointer, git_oid) {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var obj: OpaquePointer?
        let revparseError = git_revparse_single(&obj, ptr, ref)
        guard revparseError == 0, let object = obj else {
            throw Libgit2Error.referenceNotFound(ref)
        }

        let commit: OpaquePointer
        if git_object_type(object) != GIT_OBJECT_COMMIT {
            var peeled: OpaquePointer?
            let peelError = git_object_peel(&peeled, object, GIT_OBJECT_COMMIT)
            git_object_free(object)
            guard peelError == 0, let p = peeled else {
                throw Libgit2Error.from(peelError, context: "peel to commit")
            }
            commit = p
        } else {
            commit = object
        }

        var oid = git_oid()
        if let oidPtr = git_commit_id(commit) {
            oid = oidPtr.pointee
        }

        return (commit, oid)
    }

    /// Format libgit2 diff as unified diff string
    private func formatDiffAsUnified(_ diff: OpaquePointer) -> String {
        var output = ""
        let maxBytes = 4_000_000
        var bytesWritten = 0

        let numDeltas = git_diff_num_deltas(diff)
        for i in 0..<numDeltas {
            var patch: OpaquePointer?
            guard git_patch_from_diff(&patch, diff, i) == 0, let p = patch else {
                continue
            }
            defer { git_patch_free(p) }

            // Get patch as string using git_patch_to_buf
            var buf = git_buf()
            defer { git_buf_dispose(&buf) }

            if git_patch_to_buf(&buf, p) == 0, let ptr = buf.ptr {
                let remaining = maxBytes - bytesWritten
                if remaining <= 0 {
                    output += "\n... diff truncated (too large) ...\n"
                    break
                }

                let take = min(Int(buf.size), remaining)
                let raw = UnsafeRawBufferPointer(start: ptr, count: take)
                output += String(decoding: raw, as: UTF8.self)
                bytesWritten += take

                if take < Int(buf.size) {
                    output += "\n... diff truncated (too large) ...\n"
                    break
                }
            }
        }

        return output
    }
}
