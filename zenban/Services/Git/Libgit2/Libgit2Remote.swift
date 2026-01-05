import Foundation
import Clibgit2

/// Remote information
nonisolated struct Libgit2RemoteInfo: Sendable {
    let name: String
    let url: String?
    let pushUrl: String?
}

/// Remote operations extension for Libgit2Repository
nonisolated extension Libgit2Repository {

    private struct SSHRemoteURLParts: Sendable {
        let isSSH: Bool
        let isSCP: Bool
        let user: String?
        let host: String
        let path: String
        let port: Int?
    }

    private func parseSSHRemoteURL(_ url: String) -> SSHRemoteURLParts? {
        if url.hasPrefix("ssh://"), let u = URL(string: url), let host = u.host {
            let user = u.user
            let port = u.port
            let path = u.path
            return SSHRemoteURLParts(isSSH: true, isSCP: false, user: user, host: host, path: path, port: port)
        }

        if !url.contains("://"), let colonIndex = url.firstIndex(of: ":") {
            let before = String(url[..<colonIndex])
            let after = String(url[url.index(after: colonIndex)...])
            guard !before.contains("/"), !after.isEmpty else { return nil }

            let user: String?
            let host: String
            if let at = before.firstIndex(of: "@") {
                user = String(before[..<at])
                host = String(before[before.index(after: at)...])
            } else {
                user = nil
                host = before
            }

            guard !host.isEmpty else { return nil }
            return SSHRemoteURLParts(isSSH: true, isSCP: true, user: user, host: host, path: after, port: nil)
        }

        return nil
    }

    private func buildResolvedSSHURL(from parts: SSHRemoteURLParts, resolution: SSHConfigResolution?) -> String? {
        guard parts.isSSH else { return nil }

        let connectHost = resolution?.hostName?.isEmpty == false ? resolution!.hostName! : parts.host
        let user = parts.user ?? resolution?.user
        let port = resolution?.port ?? parts.port

        if parts.isSCP, (port == nil || port == 22) {
            let userPrefix = (user?.isEmpty == false) ? "\(user!)@" : ""
            return "\(userPrefix)\(connectHost):\(parts.path)"
        }

        var components = URLComponents()
        components.scheme = "ssh"
        components.host = connectHost
        components.user = user
        components.port = port

        let path = parts.isSCP ? "/\(parts.path)" : (parts.path.hasPrefix("/") ? parts.path : "/\(parts.path)")
        components.path = path

        return components.url?.absoluteString
    }

    private func prepareSSHCallbacksPayload(originalHost: String) -> UnsafeMutablePointer<SSHCredentialPayload> {
        let payload = UnsafeMutablePointer<SSHCredentialPayload>.allocate(capacity: 1)
        let hostDup = strdup(originalHost)
        payload.initialize(to: SSHCredentialPayload(keyHost: hostDup))
        return payload
    }

    private func freeSSHCallbacksPayload(_ payload: UnsafeMutablePointer<SSHCredentialPayload>?) {
        guard let payload else { return }
        if let host = payload.pointee.keyHost {
            free(host)
        }
        payload.deinitialize(count: 1)
        payload.deallocate()
    }

    private func configureRemoteInstanceURLIfNeeded(remote: OpaquePointer, forPush: Bool) -> UnsafeMutablePointer<SSHCredentialPayload>? {
        let rawURLPtr = forPush ? git_remote_pushurl(remote) : git_remote_url(remote)
        guard let rawURLPtr else { return nil }
        let rawURL = String(cString: rawURLPtr)

        guard let parts = parseSSHRemoteURL(rawURL) else { return nil }

        let resolution = resolveSSHConfig(forHost: parts.host)
        let resolvedURL = buildResolvedSSHURL(from: parts, resolution: resolution)

        if let resolvedURL, resolvedURL != rawURL {
            resolvedURL.withCString { cStr in
                if forPush {
                    _ = git_remote_set_instance_pushurl(remote, cStr)
                } else {
                    _ = git_remote_set_instance_url(remote, cStr)
                }
            }
        }

        return prepareSSHCallbacksPayload(originalHost: parts.host)
    }

    /// List all remotes
    func listRemotes() throws -> [Libgit2RemoteInfo] {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var strarray = git_strarray()
        defer { git_strarray_free(&strarray) }

        let listError = git_remote_list(&strarray, ptr)
        guard listError == 0 else {
            throw Libgit2Error.from(listError, context: "remote list")
        }

        var result: [Libgit2RemoteInfo] = []

        for i in 0..<strarray.count {
            guard let namePtr = strarray.strings[i] else { continue }
            let name = String(cString: namePtr)

            var remote: OpaquePointer?
            guard git_remote_lookup(&remote, ptr, name) == 0, let r = remote else {
                continue
            }
            defer { git_remote_free(r) }

            let url = git_remote_url(r).map { String(cString: $0) }
            let pushUrl = git_remote_pushurl(r).map { String(cString: $0) }

            result.append(Libgit2RemoteInfo(
                name: name,
                url: url,
                pushUrl: pushUrl ?? url
            ))
        }

        return result
    }

    /// Get default remote (origin or first available)
    func defaultRemote() throws -> Libgit2RemoteInfo? {
        let remotes = try listRemotes()
        return remotes.first { $0.name == "origin" } ?? remotes.first
    }

    /// Push to remote
    func push(remoteName: String = "origin", refspecs: [String]? = nil, force: Bool = false, shouldSetUpstream: Bool = false) throws {
        guard let ptr = pointer else {
            throw Libgit2Error.notARepository(path)
        }

        var remote: OpaquePointer?
        let lookupError = git_remote_lookup(&remote, ptr, remoteName)
        guard lookupError == 0, let r = remote else {
            throw Libgit2Error.from(lookupError, context: "remote lookup")
        }
        defer { git_remote_free(r) }

        var opts = git_push_options()
        git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))

        opts.callbacks.credentials = sshCredentialCallback
        let payload = configureRemoteInstanceURLIfNeeded(remote: r, forPush: true)
        opts.callbacks.payload = payload.map { UnsafeMutableRawPointer($0) }

        var refs: [String]
        if let specified = refspecs {
            refs = specified
        } else {
            if let branch = try currentBranchName() {
                let refspec = force ? "+refs/heads/\(branch):refs/heads/\(branch)" : "refs/heads/\(branch)"
                refs = [refspec]
            } else {
                throw Libgit2Error.referenceNotFound("HEAD")
            }
        }

        var strarray = git_strarray()
        var cStrings = refs.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        cStrings.withUnsafeMutableBufferPointer { buffer in
            strarray.strings = buffer.baseAddress
            strarray.count = refs.count
        }

        let pushError = git_remote_push(r, &strarray, &opts)
        freeSSHCallbacksPayload(payload)
        guard pushError == 0 else {
            if pushError == Int32(GIT_EAUTH.rawValue) {
                throw Libgit2Error.authenticationFailed(remoteName)
            }
            throw Libgit2Error.from(pushError, context: "remote push")
        }

        if shouldSetUpstream, let branch = try currentBranchName() {
            try setUpstream(branch: branch, upstream: "\(remoteName)/\(branch)")
        }
    }
}
