import Foundation
import Clibgit2

/// Branch type
nonisolated enum Libgit2BranchType {
    case local
    case remote
    case all

    var gitType: git_branch_t {
        switch self {
        case .local: return GIT_BRANCH_LOCAL
        case .remote: return GIT_BRANCH_REMOTE
        case .all: return GIT_BRANCH_ALL
        }
    }
}

/// Branch information
nonisolated struct Libgit2BranchInfo: Sendable {
    let name: String
    let fullName: String
    let isRemote: Bool
    let isHead: Bool
    let upstream: String?
    let aheadBehind: (ahead: Int, behind: Int)?
}

/// Branch operations extension for Libgit2Repository
nonisolated extension Libgit2Repository {

    /// List all branches
    func listBranches(type: Libgit2BranchType = .all, includeUpstreamInfo: Bool = false) throws -> [Libgit2BranchInfo] {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var iterator: OpaquePointer?
        let iterError = git_branch_iterator_new(&iterator, ptr, type.gitType)
        guard iterError == 0, let iter = iterator else {
            throw Libgit2Error.from(iterError, context: "branch iterator")
        }
        defer { git_branch_iterator_free(iter) }

        var result: [Libgit2BranchInfo] = []
        var ref: OpaquePointer?
        var branchType: git_branch_t = GIT_BRANCH_LOCAL

        while git_branch_next(&ref, &branchType, iter) == 0 {
            guard let reference = ref else { continue }
            defer { git_reference_free(reference) }

            guard let namePtr = git_reference_shorthand(reference) else { continue }
            let name = String(cString: namePtr)

            guard let fullNamePtr = git_reference_name(reference) else { continue }
            let fullName = String(cString: fullNamePtr)

            let isRemote = branchType == GIT_BRANCH_REMOTE
            let isHead = git_branch_is_head(reference) != 0

            // Get upstream if local branch
            var upstream: String? = nil
            var aheadBehind: (ahead: Int, behind: Int)? = nil

            if includeUpstreamInfo, !isRemote {
                var upstreamRef: OpaquePointer?
                if git_branch_upstream(&upstreamRef, reference) == 0, let ur = upstreamRef {
                    defer { git_reference_free(ur) }
                    if let upstreamName = git_reference_shorthand(ur) {
                        upstream = String(cString: upstreamName)
                    }

                    // Calculate ahead/behind
                    var localOid = git_oid()
                    var upstreamOid = git_oid()

                    if git_reference_name_to_id(&localOid, ptr, fullName) == 0,
                       let urName = git_reference_name(ur),
                       git_reference_name_to_id(&upstreamOid, ptr, urName) == 0 {
                        var ahead: Int = 0
                        var behind: Int = 0
                        if git_graph_ahead_behind(&ahead, &behind, ptr, &localOid, &upstreamOid) == 0 {
                            aheadBehind = (ahead, behind)
                        }
                    }
                }
            }

            result.append(Libgit2BranchInfo(
                name: name,
                fullName: fullName,
                isRemote: isRemote,
                isHead: isHead,
                upstream: upstream,
                aheadBehind: aheadBehind
            ))
        }

        return result
    }

    /// Delete a branch
    func deleteBranch(name: String) throws {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var branch: OpaquePointer?
        let lookupError = git_branch_lookup(&branch, ptr, name, GIT_BRANCH_LOCAL)
        guard lookupError == 0, let b = branch else {
            throw Libgit2Error.branchNotFound(name)
        }
        defer { git_reference_free(b) }

        if git_branch_is_head(b) != 0 {
            throw Libgit2Error.checkoutError("Cannot delete the currently checked out branch")
        }

        let deleteError = git_branch_delete(b)
        guard deleteError == 0 else {
            throw Libgit2Error.from(deleteError, context: "branch delete")
        }
    }

    /// Checkout a branch
    func checkoutBranch(name: String) throws {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var branch: OpaquePointer?
        let lookupError = git_branch_lookup(&branch, ptr, name, GIT_BRANCH_LOCAL)
        guard lookupError == 0, let b = branch else {
            throw Libgit2Error.branchNotFound(name)
        }
        defer { git_reference_free(b) }

        var commit: OpaquePointer?
        let peelError = git_reference_peel(&commit, b, GIT_OBJECT_COMMIT)
        guard peelError == 0, let c = commit else {
            throw Libgit2Error.from(peelError, context: "peel branch")
        }
        defer { git_commit_free(c) }

        var tree: OpaquePointer?
        let treeError = git_commit_tree(&tree, c)
        guard treeError == 0, let t = tree else {
            throw Libgit2Error.from(treeError, context: "get commit tree")
        }
        defer { git_tree_free(t) }

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)

        let checkoutError = git_checkout_tree(ptr, t, &checkoutOpts)
        guard checkoutError == 0 else {
            if checkoutError == Int32(GIT_EUNMERGED.rawValue) {
                throw Libgit2Error.uncommittedChanges("Checkout would overwrite uncommitted changes")
            }
            throw Libgit2Error.from(checkoutError, context: "checkout tree")
        }

        guard let refName = git_reference_name(b) else {
            throw Libgit2Error.referenceNotFound(name)
        }

        let setHeadError = git_repository_set_head(ptr, refName)
        guard setHeadError == 0 else {
            throw Libgit2Error.from(setHeadError, context: "set HEAD")
        }
    }

    /// Set upstream for a branch
    func setUpstream(branch: String, upstream: String?) throws {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var branchRef: OpaquePointer?
        let lookupError = git_branch_lookup(&branchRef, ptr, branch, GIT_BRANCH_LOCAL)
        guard lookupError == 0, let b = branchRef else {
            throw Libgit2Error.branchNotFound(branch)
        }
        defer { git_reference_free(b) }

        let setError = git_branch_set_upstream(b, upstream)
        guard setError == 0 else {
            throw Libgit2Error.from(setError, context: "set upstream")
        }
    }
}
