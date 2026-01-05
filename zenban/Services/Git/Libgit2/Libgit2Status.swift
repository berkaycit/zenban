import Foundation
import Clibgit2

/// File status flags
nonisolated struct Libgit2FileStatus: OptionSet, Sendable {
    let rawValue: UInt32

    static let indexNew = Libgit2FileStatus(rawValue: GIT_STATUS_INDEX_NEW.rawValue)
    static let indexModified = Libgit2FileStatus(rawValue: GIT_STATUS_INDEX_MODIFIED.rawValue)
    static let indexDeleted = Libgit2FileStatus(rawValue: GIT_STATUS_INDEX_DELETED.rawValue)
    static let indexRenamed = Libgit2FileStatus(rawValue: GIT_STATUS_INDEX_RENAMED.rawValue)
    static let indexTypeChange = Libgit2FileStatus(rawValue: GIT_STATUS_INDEX_TYPECHANGE.rawValue)

    static let wtNew = Libgit2FileStatus(rawValue: GIT_STATUS_WT_NEW.rawValue)
    static let wtModified = Libgit2FileStatus(rawValue: GIT_STATUS_WT_MODIFIED.rawValue)
    static let wtDeleted = Libgit2FileStatus(rawValue: GIT_STATUS_WT_DELETED.rawValue)
    static let wtRenamed = Libgit2FileStatus(rawValue: GIT_STATUS_WT_RENAMED.rawValue)
    static let wtTypeChange = Libgit2FileStatus(rawValue: GIT_STATUS_WT_TYPECHANGE.rawValue)
    static let wtUnreadable = Libgit2FileStatus(rawValue: GIT_STATUS_WT_UNREADABLE.rawValue)

    static let ignored = Libgit2FileStatus(rawValue: GIT_STATUS_IGNORED.rawValue)
    static let conflicted = Libgit2FileStatus(rawValue: GIT_STATUS_CONFLICTED.rawValue)

    /// File is staged (in index)
    var isStaged: Bool {
        !intersection([.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange]).isEmpty
    }

    /// File has unstaged changes
    var isModified: Bool {
        !intersection([.wtModified, .wtDeleted, .wtTypeChange]).isEmpty
    }

    /// File is untracked
    var isUntracked: Bool {
        contains(.wtNew)
    }

    /// File has conflicts
    var isConflicted: Bool {
        contains(.conflicted)
    }
}

/// Status entry for a single file
nonisolated struct Libgit2StatusEntry: Sendable {
    let path: String
    let oldPath: String?  // For renames
    let status: Libgit2FileStatus

    /// Simplified status category
    var category: StatusCategory {
        if status.isConflicted { return .conflicted }
        if status.isStaged && !status.isModified && !status.isUntracked { return .staged }
        if status.isModified { return .modified }
        if status.isUntracked { return .untracked }
        if status.isStaged { return .staged }
        return .clean
    }

    enum StatusCategory: Sendable {
        case staged
        case modified
        case untracked
        case conflicted
        case clean
    }
}

/// Repository status summary
nonisolated struct Libgit2StatusSummary: Sendable {
    let entries: [Libgit2StatusEntry]
    let staged: [Libgit2StatusEntry]
    let modified: [Libgit2StatusEntry]
    let untracked: [Libgit2StatusEntry]
    let conflicted: [Libgit2StatusEntry]

    var hasChanges: Bool {
        !staged.isEmpty || !modified.isEmpty || !untracked.isEmpty || !conflicted.isEmpty
    }
}

/// Status operations extension for Libgit2Repository
nonisolated extension Libgit2Repository {

    /// Get repository status
    func status(includeUntracked: Bool = true, includeIgnored: Bool = false) throws -> Libgit2StatusSummary {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var opts = git_status_options()
        git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))

        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = UInt32(GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue) |
                     UInt32(GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue)

        if includeUntracked {
            opts.flags |= UInt32(GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue)
        }
        if includeIgnored {
            opts.flags |= UInt32(GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue)
        }

        var statusList: OpaquePointer?
        let listError = git_status_list_new(&statusList, ptr, &opts)
        guard listError == 0, let list = statusList else {
            throw Libgit2Error.from(listError, context: "status list")
        }
        defer { git_status_list_free(list) }

        var entries: [Libgit2StatusEntry] = []
        let count = git_status_list_entrycount(list)

        for i in 0..<count {
            guard let entry = git_status_byindex(list, i) else { continue }

            let status = Libgit2FileStatus(rawValue: entry.pointee.status.rawValue)

            // Get path from head_to_index or index_to_workdir
            var path: String = ""
            var oldPath: String? = nil

            if let headToIndex = entry.pointee.head_to_index {
                if let newFile = headToIndex.pointee.new_file.path {
                    path = String(cString: newFile)
                }
                if let oldFile = headToIndex.pointee.old_file.path {
                    let old = String(cString: oldFile)
                    if old != path {
                        oldPath = old
                    }
                }
            }

            if path.isEmpty, let indexToWorkdir = entry.pointee.index_to_workdir {
                if let newFile = indexToWorkdir.pointee.new_file.path {
                    path = String(cString: newFile)
                }
                if let oldFile = indexToWorkdir.pointee.old_file.path {
                    let old = String(cString: oldFile)
                    if old != path {
                        oldPath = old
                    }
                }
            }

            guard !path.isEmpty else { continue }

            entries.append(Libgit2StatusEntry(
                path: path,
                oldPath: oldPath,
                status: status
            ))
        }

        // Categorize entries
        let staged = entries.filter { $0.category == .staged }
        let modified = entries.filter { $0.category == .modified }
        let untracked = entries.filter { $0.category == .untracked }
        let conflicted = entries.filter { $0.category == .conflicted }

        return Libgit2StatusSummary(
            entries: entries,
            staged: staged,
            modified: modified,
            untracked: untracked,
            conflicted: conflicted
        )
    }

    /// Stage all changes (additions, modifications, deletions)
    func stageAll() throws {
        guard pointer != nil else {
            throw Libgit2Error.notARepository(path)
        }

        let index = try getIndex()
        defer { git_index_free(index) }

        var pathspec = git_strarray()
        var patterns: [UnsafeMutablePointer<CChar>?] = [strdup("*")]
        defer { patterns.forEach { free($0) } }

        // Add new (untracked) files
        let addError: Int32 = patterns.withUnsafeMutableBufferPointer { buffer in
            pathspec.strings = buffer.baseAddress
            pathspec.count = 1
            return git_index_add_all(index, &pathspec, UInt32(GIT_INDEX_ADD_DEFAULT.rawValue), nil, nil)
        }
        guard addError == 0 else {
            throw Libgit2Error.from(addError, context: "index add all")
        }

        // Update tracked files (handles modifications and deletions)
        let updateError: Int32 = patterns.withUnsafeMutableBufferPointer { buffer in
            pathspec.strings = buffer.baseAddress
            pathspec.count = 1
            return git_index_update_all(index, &pathspec, nil, nil)
        }
        guard updateError == 0 else {
            throw Libgit2Error.from(updateError, context: "index update all")
        }

        let writeError = git_index_write(index)
        guard writeError == 0 else {
            throw Libgit2Error.from(writeError, context: "index write")
        }
    }
}
