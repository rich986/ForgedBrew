import Foundation

nonisolated enum BrewCLIError: Error, Sendable {
    case executableNotFound
    case processError(String)
}

// Thread-safe one-shot latch: fire() returns true exactly once. Used so the
// brew lock is released a single time even though both the process termination
// handler and the launch-failure catch can call the release closure.
nonisolated final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// Thread-safe holder for a launch error captured inside the
// withCheckedContinuation closure (a non-escaping context that can't mutate a
// local `var`). Lets collect() detect a process.run() failure reliably without
// inspecting the Process's post-failure status fields.
nonisolated final class LaunchErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) {
        lock.lock(); defer { lock.unlock() }
        error = e
    }
    var value: Error? {
        lock.lock(); defer { lock.unlock() }
        return error
    }
}

// Rolling byte buffer used by the process-output reader to reassemble brew's
// output into whole lines across pipe reads. A reference type so the
// readabilityHandler closure (invoked serially on the pipe's own dispatch
// queue) can mutate it without capturing a mutable `var` — mirroring the
// OneShot pattern. The lock guards against the (rare) overlap with the
// termination handler.
nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    // Appends new bytes and returns every complete line they produced, keeping
    // the trailing partial line buffered for the next read.
    func appendAndExtractLines(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let idx = pending.firstIndex(of: newline) {
            let lineData = pending.subdata(in: pending.startIndex..<idx)
            pending.removeSubrange(pending.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    // Flushes whatever is left (the final line with no trailing newline).
    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty, let tail = String(data: pending, encoding: .utf8) else {
            pending.removeAll()
            return nil
        }
        pending.removeAll()
        return tail
    }
}

actor BrewCLIService {
    static let shared = BrewCLIService()
    private init() {}

    // MARK: - Serial brew gate
    //
    // Homebrew holds a single global lock for any write operation (install /
    // upgrade / reinstall / uninstall / cleanup). If two of these run at once
    // — e.g. the user updates two apps together — the second brew process
    // blocks on that lock, and because each of our operations ends with its own
    // `brew cleanup`, the contention surfaces as an apparent hang on the
    // "Cleaning up" step. To avoid it we serialize EVERY brew subprocess here:
    // only one runs at a time, the next starts when the current one's process
    // has fully terminated. (We deliberately gate brew behind a
    // lock and reports "Another Homebrew operation is in progress".)
    //
    // FIFO fairness: waiters are resumed in arrival order.
    private var brewBusy = false
    private var brewWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireBrewLock() async {
        if !brewBusy {
            brewBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            brewWaiters.append(cont)
        }
        // Resumed by releaseBrewLock(), which hands us ownership directly
        // (brewBusy stays true), so nothing else can slip in between.
    }

    private func releaseBrewLock() {
        if brewWaiters.isEmpty {
            brewBusy = false
        } else {
            // Hand ownership straight to the next waiter; keep brewBusy true.
            let next = brewWaiters.removeFirst()
            next.resume()
        }
    }

    private var brewPath: String {
        get throws {
            let appleSilicon = "/opt/homebrew/bin/brew"
            let intel = "/usr/local/bin/brew"
            if FileManager.default.fileExists(atPath: appleSilicon) { return appleSilicon }
            if FileManager.default.fileExists(atPath: intel) { return intel }
            throw BrewCLIError.executableNotFound
        }
    }

    private static func stripANSI(_ string: String) -> String {
        let ansiRegex = /\x1B\[[0-9;]*[mGKHF]/
        return string.replacing(ansiRegex, with: "")
    }

    private func run(_ arguments: [String]) async throws -> AsyncStream<String> {
        try await run(arguments, sudoPassword: nil)
    }

    // Paths to the askpass helper and the one-shot password file it reads.
    nonisolated struct AskpassAssets {
        let scriptPath: String
        let passwordFilePath: String
    }

    // Writes the SUDO_ASKPASS helper script AND a sibling password file.
    //
    // WHY A FILE (not just an env var): brew authenticates with `sudo -A`, and
    // sudo runs the askpass program in a RESET environment (macOS sudoers
    // defaults to `env_reset`). That strips FORGEDBREW_ASKPASS_PASSWORD before our
    // helper ever runs, so an env-only helper prints an empty line and sudo
    // rejects it — the exact "Sorry, try again / 3 incorrect password attempts"
    // loop. The reliable channel is a temp file the helper `cat`s; the file
    // path is baked into the script at write time, so it survives env_reset.
    // The env var is kept as a best-effort fast path. (This is how our
    // askpass helper is wired.)
    //
    // The password file is 0600 (owner-only), lives in the per-user temp dir,
    // and is deleted as soon as the run finishes (see run(_:sudoPassword:)).
    private static func writeAskpassAssets(password: String) -> AskpassAssets? {
        let dir = NSTemporaryDirectory()
        let scriptURL = URL(fileURLWithPath: dir).appendingPathComponent("forgedbrew-askpass.sh")
        let pwURL = URL(fileURLWithPath: dir).appendingPathComponent("forgedbrew-askpass-pw")
        // sudo strips exactly one trailing newline from the askpass output, so
        // the file holds `password\n`; `cat` then emits `password\n` and sudo
        // sees `password`. The password is written verbatim — no trimming here
        // (trimming happens upstream when captured) so trailing spaces a user
        // genuinely typed are preserved.
        let pwBytes = Data((password + "\n").utf8)
        // Helper: prefer the file (reliable under env_reset); fall back to the
        // env var if for some reason the file is missing.
        let body = """
        #!/bin/sh
        if [ -f "\(pwURL.path)" ]; then
          cat "\(pwURL.path)"
        elif [ -n "$FORGEDBREW_ASKPASS_PASSWORD" ]; then
          printf '%s\\n' "$FORGEDBREW_ASKPASS_PASSWORD"
        fi
        """
        do {
            // Write the password file first, locked down to owner-only.
            try pwBytes.write(to: pwURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pwURL.path
            )
            // Then the helper script, owner read/write/execute only.
            try body.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
            return AskpassAssets(scriptPath: scriptURL.path, passwordFilePath: pwURL.path)
        } catch {
            // Best-effort cleanup if we got partway.
            try? FileManager.default.removeItem(at: pwURL)
            return nil
        }
    }

    // Core process runner. When `sudoPassword` is non-nil, brew is run with an
    // askpass helper so any `sudo` step it performs (e.g. installing a `pkg`
    // cask like Microsoft Office) authenticates non-interactively instead of
    // hanging on a `Password:` prompt that has no TTY.
    private func run(_ arguments: [String], sudoPassword: String?) async throws -> AsyncStream<String> {
        let path = try brewPath
        let askpass = sudoPassword.flatMap { BrewCLIService.writeAskpassAssets(password: $0) }

        // Serialize against every other brew subprocess. Acquire BEFORE the
        // process starts; the lock is released exactly once when the process
        // terminates (or fails to launch) via releaseBrewLock(). Because each
        // operation also ends with `brew cleanup`, this is what prevents the
        // "hang on cleanup" when two updates run together.
        await acquireBrewLock()

        // Release the lock exactly once, hopping back onto the actor (the
        // termination handler fires on an arbitrary thread).
        let releaseOnce = OneShot()
        let release: @Sendable () -> Void = { [weak self] in
            guard releaseOnce.fire() else { return }
            Task { await self?.releaseBrewLock() }
        }

        return AsyncStream<String> { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            // Non-interactive sudo wiring. Setting SUDO_ASKPASS makes brew use
            // `sudo -A`; the helper script feeds back the password. The reliable
            // channel is the password file the helper reads (survives sudo's
            // env_reset); the env var is a best-effort fast path only.
            if let password = sudoPassword, let askpass {
                env["SUDO_ASKPASS"] = askpass.scriptPath
                env["FORGEDBREW_ASKPASS_PASSWORD"] = password
                // Belt and suspenders: tell brew not to auto-update mid-run and
                // to avoid env hints cluttering the log.
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                env["HOMEBREW_NO_ENV_HINTS"] = "1"
            }
            process.environment = env

            // Delete the one-shot password file as soon as the run ends (success
            // or failure). Called from both the termination handler and the
            // run-failure path so the secret never lingers on disk.
            let pwFilePath = askpass?.passwordFilePath
            let wipePasswordFile: () -> Void = {
                if let pwFilePath {
                    try? FileManager.default.removeItem(atPath: pwFilePath)
                }
            }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // The stream is finished EXACTLY ONCE — from whichever of the two
            // paths below gets there first (normally the pipe EOF). Guarding it
            // lets the termination handler be a pure safety net.
            let finishOnce = OneShot()
            let finishStream: @Sendable () -> Void = {
                guard finishOnce.fire() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                wipePasswordFile()
                release()
                continuation.finish()
            }

            // Reassembles brew's output into whole lines. brew writes faster than
            // we decode, and a single read can split a line down the middle, so
            // we keep a rolling buffer and only emit up to the last newline; the
            // remainder carries into the next chunk (and is flushed at EOF).
            //
            // WHY THIS SHAPE MATTERS: stdout+stderr share one 64 KB pipe. The
            // ONLY way to keep brew from blocking on a full-pipe write() — which
            // would stop it ever terminating and leave the UI stuck on
            // "Cleaning up…" during the chatty `brew cleanup -s -v` — is to
            // drain the pipe continuously here. An empty read is the pipe's EOF
            // signal (the write end closed because brew exited): that's when we
            // flush the tail and finish the stream, so no output is ever lost.
            let lineBuffer = LineBuffer()
            let emit: @Sendable (String) -> Void = { chunk in
                let stripped = BrewCLIService.stripANSI(chunk)
                if !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.yield(stripped)
                }
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    // EOF: brew closed its end. Flush any trailing partial line,
                    // then finish. (The termination handler is the backstop, but
                    // EOF normally beats it.)
                    if let tail = lineBuffer.flush() { emit(tail) }
                    finishStream()
                    return
                }
                for line in lineBuffer.appendAndExtractLines(data) {
                    emit(line)
                }
            }

            // Safety net only. The readabilityHandler's EOF (empty read) is the
            // primary completion path and fires whenever brew exits normally —
            // it flushes the tail and finishes the stream. This handler exists
            // for the abnormal case where the process goes away without the pipe
            // ever delivering EOF (e.g. it was force-killed); we don't touch the
            // pipe here (the readabilityHandler owns it on its serial queue),
            // we just guarantee teardown. finishStream() is OneShot-guarded, so
            // when EOF already finished the stream this is a no-op.
            process.terminationHandler = { _ in
                finishStream()
            }

            do {
                try process.run()
            } catch {
                finishStream()
            }
        }
    }

    func install(cask: String) async -> AsyncStream<String> {
        do {
            return try await run(["install", "--cask", cask])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func uninstall(cask: String) async -> AsyncStream<String> {
        do {
            return try await run(["uninstall", "--cask", cask])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func upgrade(cask: String) async -> AsyncStream<String> {
        do {
            return try await run(["upgrade", "--cask", cask])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func upgradeAll() async -> AsyncStream<String> {
        do {
            return try await run(["upgrade", "--greedy"])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func installFormula(_ name: String) async -> AsyncStream<String> {
        do {
            return try await run(["install", name])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func uninstallFormula(_ name: String) async -> AsyncStream<String> {
        do {
            return try await run(["uninstall", "--formula", name])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func upgradeFormula(_ name: String) async -> AsyncStream<String> {
        do {
            return try await run(["upgrade", "--formula", name])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    // MARK: - Sudo-aware operations
    //
    // These mirror the operations above but thread an admin password through to
    // the askpass helper so privileged casks (those shipping a `pkg` installer,
    // e.g. Microsoft Office) can install/upgrade/uninstall without hanging on a
    // `Password:` prompt. A nil password falls back to the non-privileged path.

    private func errorStream(_ error: Error) -> AsyncStream<String> {
        AsyncStream<String> { continuation in
            continuation.yield("Error: \(error.localizedDescription)")
            continuation.finish()
        }
    }

    func install(cask: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["install", "--cask", cask], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func upgrade(cask: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["upgrade", "--cask", cask], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    // Forced reinstall of a cask: `brew reinstall --cask --force <token>`.
    //
    // Used as the automatic fallback when a normal `brew upgrade --cask` aborts
    // on the uninstall-old step. Some casks (notably the Microsoft Office apps)
    // share a support directory like `/Library/Application Support/Microsoft`
    // that holds the common `MAU2.0/Microsoft AutoUpdate.app`. brew's upgrade
    // path removes the old version first, and its `rmdir.sh` (run under `set
    // -euo pipefail`) exits non-zero when that shared directory isn't empty,
    // which kills the whole upgrade before the new version is poured. A forced
    // reinstall pours the new version directly without that pre-removal step, so
    // it sidesteps the failure. By design we route problematic
    // cask upgrades through `brew install --cask --force` for the same reason.
    // `--force` lets brew replace the already-present app bundle in place.
    func reinstall(cask: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["reinstall", "--cask", "--force", cask], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func uninstall(cask: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["uninstall", "--cask", cask], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func uninstallZap(cask: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["uninstall", "--cask", "--zap", cask], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func upgradeAll(sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["upgrade", "--greedy"], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    // "Update All" that EXCLUDES parked packages: instead of the blanket
    // `brew upgrade --greedy` (which would upgrade everything outdated), we pass
    // brew an explicit list of just the tokens we want upgraded. brew accepts a
    // mixed cask/formula token list on `brew upgrade <names...>` and resolves
    // each, so a single pass still handles both. `--greedy` is kept so casks
    // that self-update are still eligible (matching the un-parked Update All
    // behavior); parked tokens simply aren't in the list, so brew never touches
    // them. An empty list is a no-op (nothing to upgrade once parks are removed).
    func upgrade(tokens: [String], sudoPassword: String?) async -> AsyncStream<String> {
        guard !tokens.isEmpty else {
            return AsyncStream<String> { continuation in
                continuation.yield("Nothing to upgrade — all outdated packages are parked.")
                continuation.finish()
            }
        }
        do { return try await run(["upgrade", "--greedy"] + tokens, sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func installFormula(_ name: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["install", name], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func upgradeFormula(_ name: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["upgrade", "--formula", name], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    func uninstallFormula(_ name: String, sudoPassword: String?) async -> AsyncStream<String> {
        do { return try await run(["uninstall", "--formula", name], sudoPassword: sudoPassword) }
        catch { return errorStream(error) }
    }

    // Whether a cask requires administrator privileges to (un)install. A cask
    // needs sudo when it installs via a macOS `pkg` (the installer writes to
    // system paths), so we look for a `pkg` artifact in its metadata. Best
    // effort: on any parse/CLI failure we return false and rely on the runtime
    // `Password:` detection as a fallback.
    func caskRequiresSudo(_ token: String) async -> Bool {
        guard let json = try? await collect(["info", "--cask", "--json=v2", token]),
              let data = json.data(using: .utf8) else {
            return false
        }
        // Look for a top-level "artifacts" entry whose object contains a "pkg"
        // key. We parse loosely to avoid coupling to brew's full schema.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let first = casks.first,
              let artifacts = first["artifacts"] as? [[String: Any]] else {
            return false
        }
        for artifact in artifacts where artifact["pkg"] != nil {
            return true
        }
        return false
    }

    // MARK: - Up-front admin-password validation
    //
    // Verifies an admin password BEFORE we cache it or kick off any brew work.
    // This is what fixes the "a wrong password still lets the update proceed"
    // bug: for apps that don't actually invoke sudo, a bad password would never
    // be exercised, so it got cached as if valid and silently poisoned the rest
    // of the session. We now validate the password directly against `sudo`.
    //
    // Implementation: run `sudo -k -S -p '' -v` and feed the password on stdin.
    //   • `-k` invalidates any cached sudo timestamp first, so a previously
    //     valid timestamp can't make a WRONG password appear to succeed.
    //   • `-S` reads the password from stdin (no TTY needed).
    //   • `-p ''` suppresses the prompt text so it never pollutes output.
    //   • `-v` only refreshes/validates credentials; it runs no command.
    // Exit status 0 means the password was accepted; non-zero means rejected.
    // Returns true only on a clean, accepted validation.
    func validateSudoPassword(_ password: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-k", "-S", "-p", "", "-v"]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            // Make sure no inherited SUDO_ASKPASS hijacks the stdin path.
            env.removeValue(forKey: "SUDO_ASKPASS")
            process.environment = env

            let stdinPipe = Pipe()
            let outPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = outPipe
            process.standardError = outPipe

            let finished = OneShot()
            process.terminationHandler = { proc in
                guard finished.fire() else { return }
                // Drain output (ignored) so the pipe never blocks teardown.
                _ = try? outPipe.fileHandleForReading.readToEnd()
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
                // sudo strips one trailing newline; send `password\n`.
                let handle = stdinPipe.fileHandleForWriting
                handle.write(Data((password + "\n").utf8))
                try? handle.close()
            } catch {
                guard finished.fire() else { return }
                continuation.resume(returning: false)
            }
        }
    }

    // Runtime detection: does this brew output line indicate it is asking for an
    // administrator password (so we should prompt and retry with askpass)?
    nonisolated static func lineRequestsPassword(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("password:") { return true }
        if lower.contains("requires administrator")
            || lower.contains("needs administrator")
            || lower.contains("administrator privileges") {
            return true
        }
        // brew's own hint when no askpass/TTY is available.
        if lower.contains("a terminal is required to read the password") { return true }
        if lower.contains("sudo: a password is required") { return true }
        return false
    }

    func doctor() async -> AsyncStream<String> {
        do {
            return try await run(["doctor"])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    // Deep cache clean. A bare `brew cleanup` only prunes downloads older than
    // the default 120-day retention window and keeps the latest version of each
    // formula/cask's cached download. We expose this as the two-tier model the
    // user sees (our Standard / Deep cleanup):
    //
    //   • Normal Clean (`brew cleanup -v`)
    //       Removes old versions of installed formulae/casks and downloads older
    //       than the 120-day retention window. On a fresh, up-to-date system
    //       this can legitimately free nothing.
    //   • Deep Clean (`brew cleanup --prune=all -s -v`)
    //       Also removes ALL cached downloads regardless of age and scrubs the
    //       latest versions' downloads plus stale lock/symlink cruft.
    //
    // NOTE: neither command deletes the staged installer payloads (.pkg/.dmg)
    // the Caskroom keeps for *currently installed* casks — Homebrew never
    // touches those, so the Disk Usage breakdown must not count the Caskroom as
    // reclaimable-by-cleanup. `-v` makes the log show exactly what was freed.
    func normalCleanup() async -> AsyncStream<String> {
        do {
            return try await run(["cleanup", "-v"])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func deepCleanup() async -> AsyncStream<String> {
        do {
            return try await run(["cleanup", "--prune=all", "-s", "-v"])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    // Back-compat alias kept so any existing callers keep working; routes to the
    // deep clean (its previous behavior).
    func cleanup() async -> AsyncStream<String> {
        await deepCleanup()
    }

    func autoremove() async -> AsyncStream<String> {
        do {
            return try await run(["autoremove"])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    // Deep uninstall for a cask: `brew uninstall --cask --zap <token>` removes
    // the app AND its leftover support/config files (the ~/Library entries the
    // cask declares under `zap`). This is the deep-cleanup behavior the
    // Installed list's per-app Uninstall button runs, as opposed to the plain
    // `uninstall(cask:)` which leaves those files behind.
    func uninstallZap(cask: String) async -> AsyncStream<String> {
        do {
            return try await run(["uninstall", "--cask", "--zap", cask])
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    private func collect(_ arguments: [String]) async throws -> String {
        let path = try brewPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        // Separate pipes for stdout and stderr. brew writes machine-readable
        // JSON (for `info --json=v2`, `outdated --json=v2`, etc.) to STDOUT and
        // human-facing warnings to STDERR. Recent brew/tap deprecation warnings
        // (e.g. a tap's `depends_on macos:` string-compare notice) print to
        // stderr; if stderr were merged into stdout, those lines prefix the JSON
        // and JSONDecoder fails on \"line 1 column 1\", silently emptying the
        // Installed and Updates lists. Keeping the streams separate means
        // collect() returns clean stdout only. Both pipes are drained to EOF
        // off-actor and concurrently so neither can fill its 64 KB buffer and
        // deadlock the writer.
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let dataTask = Task.detached(priority: .utility) {
            outHandle.readDataToEndOfFile()
        }.value
        async let errTask = Task.detached(priority: .utility) {
            errHandle.readDataToEndOfFile()
        }.value

        // Wait for the process to exit ASYNCHRONOUSLY via its termination
        // handler — NEVER `process.waitUntilExit()`.
        //
        // WHY THIS MATTERS (the "hang on Cleaning up" bug): collect() is isolated
        // to this actor. `waitUntilExit()` is a SYNCHRONOUS, blocking call, so
        // while it waits it pins the actor's serial executor — no other
        // actor-isolated method can run. The brew write path releases its serial
        // brew lock by hopping `releaseBrewLock()` back ONTO this actor; if a
        // concurrent `collect()` (launch refresh, post-install refresh) is
        // sitting in waitUntilExit(), that release can never execute, so a queued
        // install/upgrade stays parked behind the lock and the UI hangs on
        // "Cleaning up…". Awaiting a continuation instead suspends without
        // blocking the executor, so the lock release (and everything else) runs.
        // Set the termination handler BEFORE launching so we can never miss a
        // fast-exiting process (which would otherwise leave the continuation
        // suspended forever). A OneShot guards against the handler firing more
        // than once.
        let resumeOnce = OneShot()
        let launchError = LaunchErrorBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                if resumeOnce.fire() { cont.resume() }
            }
            do {
                try process.run()
            } catch {
                // Launch failed: no termination handler will ever fire, so
                // record the error and resume the continuation ourselves.
                launchError.set(error)
                if resumeOnce.fire() { cont.resume() }
            }
        }

        // Surface a launch failure (process never started) as a thrown error,
        // matching the previous behavior. Reading the captured error is reliable;
        // inspecting the Process's status after a failed run() is not.
        if let err = launchError.value {
            // Drain the read tasks so the detached readers don't leak.
            _ = await dataTask
            _ = await errTask
            throw BrewCLIError.processError("Failed to launch brew: \(err.localizedDescription)")
        }

        let data = await dataTask
        // Drain stderr to EOF so the detached reader completes; brew warnings
        // here are intentionally discarded — only stdout JSON is returned.
        _ = await errTask

        guard process.terminationStatus == 0 else {
            throw BrewCLIError.processError("Exit code \(process.terminationStatus)")
        }

        guard let output = String(data: data, encoding: .utf8) else {
            throw BrewCLIError.processError("Failed to decode output")
        }
        return output
    }

    func listInstalled() async throws -> String {
        // NOTE: `brew list --json=v2` is NOT valid (brew rejects it with
        // "needless argument"). The correct invocation for a machine-readable
        // manifest of installed packages is `brew info --installed --json=v2`.
        try await collect(["info", "--installed", "--json=v2"])
    }

    func listOutdated() async throws -> String {
        // Some casks (e.g. the Microsoft 365 apps, Claude) declare
        // `auto_updates true` / `version :latest` — they update themselves
        // internally, so `brew outdated` HIDES them by default. When the user
        // enables "Check apps that update themselves" (Settings), we add
        // `--greedy` so those apps are checked too. The default key value is
        // true, matching the at-a-glance behavior our users expect;
        // UserDefaults returns false for an unset key, so we treat the absence
        // of an explicit `false` as "on".
        let defaults = UserDefaults.standard
        let includeSelfUpdating = defaults.object(forKey: "forgedbrewIncludeSelfUpdatingApps") as? Bool ?? true
        var args = ["outdated", "--json=v2"]
        if includeSelfUpdating {
            args.append("--greedy")
        }
        return try await collect(args)
    }

func brewVersion() async throws -> String {
        try await collect(["--version"])
    }

    // The installed Homebrew version as a bare number string ("4.4.24"), parsed
    // from `brew --version` (whose first line reads "Homebrew 4.4.24"). Returns
    // nil if brew is missing or the output cannot be parsed.
    func installedBrewVersion() async -> String? {
        guard let raw = try? await collect(["--version"]) else { return nil }
        let firstLine = raw.components(separatedBy: "\n").first ?? raw
        // Take the first whitespace-separated token that starts with a digit,
        // tolerating "Homebrew 4.4.24" and "Homebrew 4.4.24-123-gabc" shapes.
        let tokens = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if let versionToken = tokens.first(where: { $0.first?.isNumber == true }) {
            // Trim a git-describe suffix ("4.4.24-12-gdeadbee" → "4.4.24").
            return versionToken.split(separator: "-").first.map(String.init)
                ?? String(versionToken)
        }
        return nil
    }

    // Runs `brew update`, which fetches the newest Homebrew core + taps AND
    // updates Homebrew itself (there is no separate "upgrade Homebrew" command).
    // Streams brew output line by line so the UI can show progress. We disable
    // the auto-update guard for this one call since updating IS the intent.
    func updateBrew() async -> AsyncStream<String> {
        do {
            return try await run(["update"])
        } catch {
            return errorStream(error)
        }
    }

    // Fast, synchronous check for whether Homebrew is present at all. Just a
    // filesystem existence test on the two standard brew locations (Apple
    // Silicon and Intel) — no process spawn, so it's safe to call on launch
    // before any async work. Used to decide whether to show the first-run
    // "install Homebrew" sheet to users who don't have brew yet.
    nonisolated var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
    }

    func diskUsage() async throws -> String {
        try await collect(["list", "--cask", "--versions"])
    }

    // Measures the on-disk size (in bytes) of a set of absolute paths in one
    // pass, returning a path → bytes map. Paths that don't exist are skipped.
    // Used to size installed packages: AppDataService resolves each package's
    // artifact path (a cask's /Applications bundle or a formula's Cellar keg)
    // and passes them here. We shell out to `du -sk` (kilobytes, apparent disk
    // usage) once over all paths, which is far cheaper than one Process per app.
    func sizesForPaths(_ paths: [String]) async -> [String: Int] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return [:] }

        // `du -sk <p1> <p2> …` prints one "<kb>\t<path>" line per argument.
        // Timeout-protected (hard-kills a hung `du`) so a single unreadable
        // path can't wedge the whole size pass and leave sizes "measuring…"
        // forever. On timeout/failure we return whatever lines we parsed.
        guard let (out, _) = try? await runExecutableWithStatus("/usr/bin/du", ["-sk"] + existing, timeout: 30) else {
            return [:]
        }

        var result: [String: Int] = [:]
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Split on the first tab: "<kb>\t<path>".
            let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let kb = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let path = String(parts[1])
            result[path] = kb * 1024
        }
        return result
    }

    // MARK: - Enriched maintenance data

    // Runs an arbitrary executable (not brew) and returns combined stdout/stderr.
    // Used for `du`/`/bin/sh` size probes that brew itself doesn't provide.
    private func runExecutable(_ launchPath: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let readHandle = pipe.fileHandleForReading
        let data = await Task.detached(priority: .utility) {
            readHandle.readDataToEndOfFile()
        }.value
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            throw BrewCLIError.processError("Failed to decode output")
        }
        return output
    }

    // Like runExecutable, but also returns the process's exit status. Several
    // security tools (codesign --verify, spctl --assess) signal their verdict
    // through the exit code (0 = ok / accepted, non-zero = invalid / rejected)
    // in addition to their text output, so the scan needs both.
    // A dedicated serial queue for spawning/reaping security-scan subprocesses.
    // CRITICAL: we keep ALL blocking work (pipe reads, process launch) OFF the
    // Swift concurrency cooperative thread pool. An earlier version used
    // Task.detached with blocking readDataToEndOfFile() + a usleep busy-wait;
    // across ~30 apps × 3 commands that starved the small cooperative pool and
    // wedged the whole scan partway through. This GCD queue has its own threads.
    private static let scanQueue = DispatchQueue(
        label: "forgedbrew.securityscan", qos: .utility, attributes: .concurrent
    )

    // Mutable state for one subprocess run, shared between the readability
    // handlers, the termination handler, and the timeout block. A reference
    // type (captured as a `let`) keeps Swift's concurrency checker happy and
    // its NSLock guards all access across the GCD threads.
    private final class ProcRunState: @unchecked Sendable {
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        var resumed = false
        var timedOut = false
    }

    private func runExecutableWithStatus(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 10
    ) async throws -> (output: String, status: Int32) {
        // Bridge the callback-based GCD work into async/await with a single
        // continuation. terminationHandler fires once the process exits; the
        // pipe data is read with NON-blocking readabilityHandlers that
        // accumulate into buffers, so nothing ever blocks a cooperative thread.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(output: String, status: Int32), Error>) in
            Self.scanQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Shared mutable state guarded by its lock (see ProcRunState).
                let state = ProcRunState()

                func finish(_ result: (output: String, status: Int32)?, error: Error?) {
                    state.lock.lock()
                    if state.resumed { state.lock.unlock(); return }
                    state.resumed = true
                    state.lock.unlock()
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let result {
                        continuation.resume(returning: result)
                    }
                }

                // Non-blocking incremental reads — drains pipe buffers as data
                // arrives so a full ~64KB buffer can never stall the child.
                outPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { state.lock.lock(); state.outData.append(d); state.lock.unlock() }
                }
                errPipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if !d.isEmpty { state.lock.lock(); state.errData.append(d); state.lock.unlock() }
                }

                process.terminationHandler = { proc in
                    // Stop the readability handlers and grab anything still
                    // buffered in the pipes.
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    state.lock.lock()
                    state.outData.append(restOut); state.errData.append(restErr)
                    let didTimeout = state.timedOut
                    let o = String(data: state.outData, encoding: .utf8) ?? ""
                    let e = String(data: state.errData, encoding: .utf8) ?? ""
                    state.lock.unlock()
                    if didTimeout {
                        finish(nil, error: BrewCLIError.processError("Timed out after \(Int(timeout))s"))
                    } else {
                        // codesign/spctl write their machine-readable lines to
                        // STDERR, so return both streams concatenated.
                        finish((o + e, proc.terminationStatus), error: nil)
                    }
                }

                do {
                    try process.run()
                } catch {
                    finish(nil, error: error)
                    return
                }

                // Hard timeout: terminate (then force-kill) so one misbehaving
                // tool can never hang the whole scan. terminationHandler still
                // fires after the kill and resumes the continuation.
                Self.scanQueue.asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        state.lock.lock(); state.timedOut = true; state.lock.unlock()
                        process.terminate()
                        Self.scanQueue.asyncAfter(deadline: .now() + 0.3) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Security scan

    // Resolves the installed cask app bundles to scan: decodes
    // `brew info --installed --json=v2` and returns (token, appPath) pairs for
    // every cask that has an app artifact actually present on disk. Mirrors the
    // decode AppDataService does when sizing packages.
    func installedCaskAppBundles() async throws -> [(token: String, appPath: String)] {
        let json = try await listInstalled()
        guard let data = json.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode(BrewInfoOutput.self, from: data)
        let fm = FileManager.default
        var pairs: [(token: String, appPath: String)] = []

        // Index the installed .app bundles by their normalized name once, so we
        // can resolve the on-disk bundle for casks that ship NO `app` artifact
        // (pkg-based casks like Microsoft Office). These have a nil appPath, so
        // without this they never enter the Homebrew-managed set and end up
        // double-listed under "Mac Store / Other Apps". We match the cask token
        // against installed app names using the same normalized key Adopt uses
        // ("microsoft-word" -> "microsoftword" == "Microsoft Word.app").
        let installedBundles = AppLocationSettings.installedAppBundles()
        var keyToBundlePath: [String: String] = [:]
        for bundle in installedBundles {
            let appName = bundle.name.hasSuffix(".app")
                ? String(bundle.name.dropLast(4))
                : bundle.name
            let key = BrewCLIService.adoptMatchKey(appName)
            if !key.isEmpty, keyToBundlePath[key] == nil {
                keyToBundlePath[key] = bundle.path
            }
        }

        var seenPaths = Set<String>()
        for cask in decoded.casks {
            // 1) Casks with a real `app` artifact: use it directly.
            if let appPath = cask.appPath, fm.fileExists(atPath: appPath) {
                if seenPaths.insert(appPath).inserted {
                    pairs.append((token: cask.token, appPath: appPath))
                }
                continue
            }
            // 2) pkg/binary casks (nil appPath): resolve the installed bundle by
            //    matching the cask token to an installed app name. This makes
            //    Office (microsoft-word/excel/powerpoint/…) recognized as
            //    Homebrew-managed so it shows ONLY in the Homebrew list.
            let tokenKey = BrewCLIService.adoptMatchKey(cask.token)
            if !tokenKey.isEmpty,
               let resolved = keyToBundlePath[tokenKey],
               fm.fileExists(atPath: resolved),
               seenPaths.insert(resolved).inserted {
                pairs.append((token: cask.token, appPath: resolved))
            }
        }
        return pairs
    }

    // Runs the local security checks on a single app bundle and parses the
    // output into an AppSecurityResult. No network access — this is purely
    // macOS's own codesign + spctl tooling, the same checks Gatekeeper performs
    // when you first launch an app:
    //   • codesign --verify --strict         → signature valid / tampered?
    //   • codesign -dv --verbose=2           → signing authority + Team ID +
    //                                          notarization ticket + flags
    //   • spctl --assess --type execute      → would Gatekeeper allow launch?
    func scanAppSecurity(token: String, appPath: String) async -> AppSecurityResult {
        let fm = FileManager.default
        let appName = ((appPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension

        guard fm.fileExists(atPath: appPath) else {
            return AppSecurityResult(
                token: token, appName: appName, appPath: appPath,
                codesignValid: false, signingAuthority: nil, teamIdentifier: nil,
                notarized: false, gatekeeperAccepted: false, gatekeeperSource: nil,
                isAppleSystem: false, scanError: "App bundle not found on disk"
            )
        }

        // 1) Signature validity (exit 0 == valid). We deliberately DON'T pass
        // `--deep`: Apple deprecated --deep for verification, and on large
        // Electron apps (Brave, VS Code, …) the recursive traversal of nested
        // helpers is slow and can spuriously fail even though Gatekeeper accepts
        // the app. Plain `--verify --strict` checks the top-level signature and
        // its Designated Requirement — which, combined with the spctl Gatekeeper
        // assessment below, is the trustworthy signal.
        var codesignValid = false
        if let verify = try? await runExecutableWithStatus(
            "/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", appPath]
        ) {
            codesignValid = (verify.status == 0)
        }

        // 2) Signing details — authority, Team ID, notarization ticket, flags.
        var signingAuthority: String? = nil
        var teamIdentifier: String? = nil
        var notarized = false
        var isAppleSystem = false
        if let details = try? await runExecutableWithStatus(
            "/usr/bin/codesign", ["-dv", "--verbose=2", appPath]
        ) {
            for raw in details.output.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // The FIRST Authority line is the leaf signer (e.g.
                // "Developer ID Application: Bitwarden Inc (LTZ2PFU5D6)" or
                // "Software Signing" for Apple's own binaries).
                if signingAuthority == nil, line.hasPrefix("Authority=") {
                    let value = String(line.dropFirst("Authority=".count))
                    signingAuthority = value
                    if value == "Software Signing" || value.hasPrefix("Apple") {
                        isAppleSystem = true
                    }
                } else if line.hasPrefix("TeamIdentifier=") {
                    let value = String(line.dropFirst("TeamIdentifier=".count))
                    // Apple system binaries report "not set".
                    if value != "not set" && !value.isEmpty { teamIdentifier = value }
                } else if line.hasPrefix("Notarization Ticket=") {
                    notarized = true
                }
            }
        }

        // 3) Gatekeeper assessment (exit 0 == accepted) + source classification.
        var gatekeeperAccepted = false
        var gatekeeperSource: String? = nil
        // `--verbose` (level 1) is enough: it prints the accepted/rejected
        // verdict plus a single `source=` line. We avoid `--verbose=4`, which
        // dumps thousands of per-file --prepared/--validated lines for large
        // Electron bundles — needless output that risks stalling the read.
        if let assess = try? await runExecutableWithStatus(
            "/usr/sbin/spctl", ["--assess", "--verbose", "--type", "execute", appPath]
        ) {
            gatekeeperAccepted = (assess.status == 0)
            for raw in assess.output.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("source=") {
                    gatekeeperSource = String(line.dropFirst("source=".count))
                }
                if line.contains("source=Apple System") { isAppleSystem = true }
            }
        }

        return AppSecurityResult(
            token: token, appName: appName, appPath: appPath,
            codesignValid: codesignValid,
            signingAuthority: signingAuthority,
            teamIdentifier: teamIdentifier,
            notarized: notarized,
            gatekeeperAccepted: gatekeeperAccepted,
            gatekeeperSource: gatekeeperSource,
            isAppleSystem: isAppleSystem,
            scanError: nil
        )
    }

    // Scans every installed cask app bundle and returns a complete report.
    // Bundles are scanned concurrently (bounded) for speed; each scan is
    // independent and only touches its own app.
    func scanAllInstalledCasks() async -> SecurityScanReport {
        let bundles = (try? await installedCaskAppBundles()) ?? []
        guard !bundles.isEmpty else {
            return SecurityScanReport(results: [], scannedAt: Date())
        }

        var results: [AppSecurityResult] = []
        // Bounded concurrency: process in small batches so we don't spawn dozens
        // of Processes at once on a large install.
        let batchSize = 4
        var index = 0
        while index < bundles.count {
            let slice = bundles[index..<min(index + batchSize, bundles.count)]
            await withTaskGroup(of: AppSecurityResult.self) { group in
                for bundle in slice {
                    group.addTask {
                        await self.scanAppSecurity(token: bundle.token, appPath: bundle.appPath)
                    }
                }
                for await r in group { results.append(r) }
            }
            index += batchSize
        }
        return SecurityScanReport(results: results, scannedAt: Date())
    }

    // MARK: - Trust Maintenance (upcoming Homebrew change)
    //
    // Proactively finds installed cask apps that macOS Gatekeeper would REJECT
    // today. These are the apps at risk from Homebrew dropping its cask
    // quarantine workaround (Homebrew/brew#20755): once Homebrew stops clearing
    // the "downloaded from the internet" flag for casks (support ends Sept 1,
    // 2026 for casks that fail Gatekeeper), an app Gatekeeper won't accept on
    // its own will hit the "can't be opened" wall on install/upgrade.
    //
    // We reuse the exact same local checks as the Security Scan — `spctl
    // --assess` is precisely what Gatekeeper runs at launch — and keep only the
    // apps that would actually break: Gatekeeper rejects them AND they are not
    // Apple system binaries (those never break) AND the scan itself succeeded
    // (a scan error is surfaced by the Security Scan, not treated as a trust
    // risk here). The remedy is `xattr -d com.apple.quarantine` via
    // removeQuarantine(at:), applied only to apps the user chooses to trust.
    func scanGatekeeperRisks() async -> GatekeeperRiskScanResult {
        let report = await scanAllInstalledCasks()

        // First pass: narrow to apps Gatekeeper would reject, excluding Apple
        // system binaries (never at risk) and any app whose scan errored
        // (surfaced by the Security Scan, not a trust decision here).
        let rejected = report.results.filter { r in
            r.scanError == nil && !r.isAppleSystem && !r.gatekeeperAccepted
        }

        // Second pass: build a GatekeeperRisk for EVERY rejected app. We no
        // longer drop apps that lack the com.apple.quarantine flag — those are
        // still genuinely at risk on Sept 1 (Gatekeeper rejects them), the local
        // Trust action just can't help yet. Instead we record `isQuarantined`
        // per app so the UI can split them into:
        //   • actionable  — flag present, Trust button clears it now
        //   • watch-only  — no flag to clear, shown as an informational risk
        // We still probe the flag concurrently for speed.
        let risks = await withTaskGroup(of: GatekeeperRisk.self) { group in
            for r in rejected {
                group.addTask {
                    let quarantined = await self.isQuarantined(path: r.appPath)
                    let reason = GatekeeperRiskReason.describe(
                        codesignValid: r.codesignValid,
                        teamIdentifier: r.teamIdentifier,
                        notarized: r.notarized,
                        signingAuthority: r.signingAuthority
                    )
                    let failed = GatekeeperRiskReason.failingChecks(
                        codesignValid: r.codesignValid,
                        teamIdentifier: r.teamIdentifier,
                        notarized: r.notarized,
                        signingAuthority: r.signingAuthority
                    )
                    return GatekeeperRisk(
                        token: r.token,
                        appName: r.appName,
                        appPath: r.appPath,
                        reason: reason,
                        failedChecks: failed,
                        signingAuthority: r.signingAuthority,
                        isQuarantined: quarantined
                    )
                }
            }
            var found: [GatekeeperRisk] = []
            for await risk in group {
                found.append(risk)
            }
            return found
        }

        // Sort alphabetically by app name. Done as its own statement (not chained
        // onto the withTaskGroup expression) so the compiler resolves the
        // closure-predicate sorted(by:) overload rather than the SortComparator one.
        let sortedRisks = risks.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }

        return GatekeeperRiskScanResult(risks: sortedRisks, scannedAt: Date())
    }

    // Progress-reporting variant of scanGatekeeperRisks, used by the Trust
    // Maintenance sheet so it can show a live "Scanning X of N…" bar with the
    // name of the app currently being checked. Same logic and result as the
    // batch version above, but it walks the installed apps one-by-one and calls
    // `onProgress(scanned, total, currentAppName)` before each check. The
    // callback is invoked on the main actor so the caller can update @Observable
    // UI state directly. A Gatekeeper assessment per app is the slow part, which
    // is why this can take a few minutes on a large install.
    func scanGatekeeperRisks(
        onProgress: @MainActor @Sendable (_ scanned: Int, _ total: Int, _ currentApp: String) -> Void
    ) async -> GatekeeperRiskScanResult {
        let bundles = (try? await installedCaskAppBundles()) ?? []
        let total = bundles.count
        guard total > 0 else {
            return GatekeeperRiskScanResult(risks: [], scannedAt: Date())
        }

        // Stable, predictable order so the progress display advances sensibly.
        let ordered = bundles.sorted { $0.token < $1.token }

        var found: [GatekeeperRisk] = []
        var scanned = 0
        for bundle in ordered {
            let name = ((bundle.appPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            await onProgress(scanned, total, name)

            let r = await scanAppSecurity(token: bundle.token, appPath: bundle.appPath)
            // Same filter as the batch scan: keep every app Gatekeeper would
            // reject, that isn't an Apple system binary and whose scan
            // succeeded. We no longer require the quarantine flag here — a
            // rejected app with no flag is still at risk on Sept 1, so we list
            // it and record `isQuarantined` for the UI to split actionable vs.
            // watch-only rows.
            if r.scanError == nil, !r.isAppleSystem, !r.gatekeeperAccepted {
                let quarantined = await isQuarantined(path: r.appPath)
                let reason = GatekeeperRiskReason.describe(
                    codesignValid: r.codesignValid,
                    teamIdentifier: r.teamIdentifier,
                    notarized: r.notarized,
                    signingAuthority: r.signingAuthority
                )
                let failed = GatekeeperRiskReason.failingChecks(
                    codesignValid: r.codesignValid,
                    teamIdentifier: r.teamIdentifier,
                    notarized: r.notarized,
                    signingAuthority: r.signingAuthority
                )
                found.append(GatekeeperRisk(
                    token: r.token,
                    appName: r.appName,
                    appPath: r.appPath,
                    reason: reason,
                    failedChecks: failed,
                    signingAuthority: r.signingAuthority,
                    isQuarantined: quarantined
                ))
            }
            scanned += 1
        }
        // Final tick so the bar reads N of N before results render.
        await onProgress(scanned, total, "")

        let sortedRisks = found.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        return GatekeeperRiskScanResult(risks: sortedRisks, scannedAt: Date())
    }
    // Single-cask trust check for the detail view. Finds the installed app
    // bundle for one token and returns a GatekeeperRisk if — and only if — the
    // app both fails Gatekeeper AND still carries the com.apple.quarantine flag
    // (the same condition scanGatekeeperRisks uses). Returns nil when the cask
    // is not installed, has no app bundle, is an Apple system binary, passes
    // Gatekeeper, or carries no quarantine flag — i.e. nothing for the user to
    // act on. Lets the detail view surface a "this app may not open" banner with
    // a one-tap fix at the exact moment the user is looking at the app.
    func gatekeeperRisk(forToken token: String) async -> GatekeeperRisk? {
        let bundles = (try? await installedCaskAppBundles()) ?? []
        guard let bundle = bundles.first(where: { $0.token == token }) else { return nil }

        let r = await scanAppSecurity(token: bundle.token, appPath: bundle.appPath)
        guard r.scanError == nil, !r.isAppleSystem, !r.gatekeeperAccepted else { return nil }
        // The detail-view banner offers a one-tap fix, which only does something
        // when there's a quarantine flag to clear — so this single-cask probe
        // still requires the flag (unlike the full Trust Maintenance scan, which
        // also surfaces watch-only risks). No flag → nothing to act on here.
        guard await isQuarantined(path: bundle.appPath) else { return nil }

        let reason = GatekeeperRiskReason.describe(
            codesignValid: r.codesignValid,
            teamIdentifier: r.teamIdentifier,
            notarized: r.notarized,
            signingAuthority: r.signingAuthority
        )
        let failed = GatekeeperRiskReason.failingChecks(
            codesignValid: r.codesignValid,
            teamIdentifier: r.teamIdentifier,
            notarized: r.notarized,
            signingAuthority: r.signingAuthority
        )
        return GatekeeperRisk(
            token: r.token,
            appName: r.appName,
            appPath: r.appPath,
            reason: reason,
            failedChecks: failed,
            signingAuthority: r.signingAuthority,
            isQuarantined: true
        )
    }

    // MARK: - Layer 2: CVE / Vulnerability scan (OSV.dev)
    //
    // Unlike the local Security Scan, this feature reaches the network: it asks
    // the OSV.dev open-source vulnerability database whether the installed
    // version of each package has known CVEs. OSV has no "Homebrew" ecosystem,
    // so we map each package to its upstream GitHub repository and query the
    // GIT ecosystem with that repo URL + the installed version. OSV fuzzy-matches
    // the version against affected ranges, so a returned vuln means the version
    // we have installed is actually affected.

    // Popular packages whose Homebrew download URL points at a project dist
    // server rather than GitHub, so URL parsing alone can't recover the repo.
    // Keyed by the package's BASE name (any "@version" suffix is stripped first).
    private static let repoAliasTable: [String: String] = [
        "node": "https://github.com/nodejs/node.git",
        "python": "https://github.com/python/cpython.git",
        "libuv": "https://github.com/libuv/libuv.git",
        "sqlite": "https://github.com/sqlite/sqlite.git",
        "readline": "https://github.com/bminor/readline.git",
        "openssl": "https://github.com/openssl/openssl.git",
        "curl": "https://github.com/curl/curl.git",
        "wget": "https://github.com/mirror/wget.git",
        "ffmpeg": "https://github.com/FFmpeg/FFmpeg.git",
        "git": "https://github.com/git/git.git",
        "ruby": "https://github.com/ruby/ruby.git",
        "php": "https://github.com/php/php-src.git",
        "vim": "https://github.com/vim/vim.git",
        "bash": "https://github.com/bminor/bash.git",
        "zsh": "https://github.com/zsh-users/zsh.git",
        "go": "https://github.com/golang/go.git",
        "rust": "https://github.com/rust-lang/rust.git",
        "postgresql": "https://github.com/postgres/postgres.git",
        "redis": "https://github.com/redis/redis.git",
        "nginx": "https://github.com/nginx/nginx.git",
        "imagemagick": "https://github.com/ImageMagick/ImageMagick.git",
        "libssh2": "https://github.com/libssh2/libssh2.git",
        "gnutls": "https://github.com/gnutls/gnutls.git",
        "freetype": "https://github.com/freetype/freetype.git",
        "harfbuzz": "https://github.com/harfbuzz/harfbuzz.git"
    ]

    // Strip a Homebrew "@version" suffix to get the base package name
    // (e.g. "python@3.12" -> "python", "icu4c@78" -> "icu4c").
    nonisolated private static func baseName(_ name: String) -> String {
        if let at = name.firstIndex(of: "@") {
            return String(name[..<at])
        }
        return name
    }

    // Recover the upstream GitHub repo (as a normalized
    // "https://github.com/owner/repo.git" GIT URL) from any of the candidate
    // strings (download URL, homepage), falling back to the alias table.
    nonisolated private static func githubRepoURL(
        name: String, candidates: [String?]
    ) -> String? {
        for candidate in candidates {
            guard let s = candidate, !s.isEmpty else { continue }
            if let url = parseGitHubRepo(from: s) { return url }
        }
        // Fall back to the alias table keyed on the base package name.
        if let aliased = repoAliasTable[baseName(name).lowercased()] {
            return aliased
        }
        return nil
    }

    // Pull "owner/repo" out of a github.com URL and build the GIT-ecosystem URL.
    nonisolated private static func parseGitHubRepo(from string: String) -> String? {
        guard let range = string.range(of: "github.com") else { return nil }
        var rest = String(string[range.upperBound...])
        // Drop a leading separator (":" for scp-style, "/" for https).
        if let first = rest.first, first == "/" || first == ":" {
            rest = String(rest.dropFirst())
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let owner = String(parts[0])
        var repo = String(parts[1])
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        // Guard against query strings / fragments stuck to the repo segment.
        if let q = repo.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            repo = String(repo[..<q])
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "https://github.com/\(owner)/\(repo).git"
    }

    // A package to be vulnerability-checked: its display name, kind, installed
    // version, and the GitHub repo URL we'll query OSV with (nil == unmappable).
    nonisolated struct VulnScanTarget: Sendable, Hashable {
        let kind: String        // "formula" or "cask"
        let name: String
        let version: String
        let repoURL: String?
    }

    // Build the full list of vulnerability-scan targets from `brew info`,
    // covering BOTH formulae and casks. Packages we can't map to a repo are
    // still returned (repoURL == nil) so the UI can honestly report them as
    // "not checked" rather than silently dropping them.
    func vulnerabilityScanTargets() async throws -> [VulnScanTarget] {
        let json = try await listInstalled()
        guard let data = json.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode(BrewInfoOutput.self, from: data)

        var targets: [VulnScanTarget] = []

        for f in decoded.formulae {
            let version = f.stableVersion
                ?? f.installed.first?.version
                ?? ""
            guard !version.isEmpty else { continue }
            let repo = Self.githubRepoURL(
                name: f.name,
                candidates: [f.stableURL, f.homepage]
            )
            targets.append(VulnScanTarget(
                kind: "formula", name: f.name, version: version, repoURL: repo
            ))
        }

        for c in decoded.casks {
            let version = c.version ?? ""
            guard !version.isEmpty else { continue }
            // Casks often carry a "version,build,uuid" string; OSV wants a clean
            // version. Take the first comma-separated component.
            let cleanVersion = version.split(separator: ",").first.map(String.init) ?? version
            let repo = Self.githubRepoURL(
                name: c.token,
                candidates: [c.url, c.homepage]
            )
            targets.append(VulnScanTarget(
                kind: "cask", name: c.token, version: cleanVersion, repoURL: repo
            ))
        }

        return targets
    }

    // The minimal slice of the OSV /v1/query response we decode.
    nonisolated private struct OSVResponse: Decodable {
        let vulns: [OSVVuln]?
    }
    nonisolated private struct OSVVuln: Decodable {
        let id: String
        let summary: String?
        let details: String?
        let aliases: [String]?
        let severity: [OSVSeverity]?
        let references: [OSVReference]?
        let databaseSpecific: OSVDatabaseSpecific?
        let affected: [OSVAffected]?

        enum CodingKeys: String, CodingKey {
            case id, summary, details, aliases, severity, references, affected
            case databaseSpecific = "database_specific"
        }
    }
    nonisolated private struct OSVSeverity: Decodable {
        let type: String?
        let score: String?
    }
    nonisolated private struct OSVReference: Decodable {
        let type: String?
        let url: String?
    }
    nonisolated private struct OSVDatabaseSpecific: Decodable {
        let severity: String?
    }
    nonisolated private struct OSVAffected: Decodable {
        let ecosystemSpecific: OSVEcosystemSpecific?
        let databaseSpecific: OSVDatabaseSpecific?
        enum CodingKeys: String, CodingKey {
            case ecosystemSpecific = "ecosystem_specific"
            case databaseSpecific = "database_specific"
        }
    }
    nonisolated private struct OSVEcosystemSpecific: Decodable {
        let severity: String?
    }

    // Parse a CVSS vector string's base-score-relevant pieces is non-trivial;
    // instead we read the numeric base score when the feed embeds it. CVSS
    // vectors alone (no score) fall through to string-based severity below.
    nonisolated private static func severity(from vuln: OSVVuln) -> VulnSeverity {
        // 1) Try a CVSS vector with a parseable base score is rarely present as
        //    a number; OSV severity scores are vector strings. We can't compute
        //    a CVSS score without a full calculator, so we look at any embedded
        //    qualitative severity strings first.
        if let dbSev = vuln.databaseSpecific?.severity, !dbSev.isEmpty {
            let mapped = VulnSeverity.fromString(dbSev)
            if mapped != .unknown { return mapped }
        }
        for aff in vuln.affected ?? [] {
            if let s = aff.ecosystemSpecific?.severity, !s.isEmpty {
                let mapped = VulnSeverity.fromString(s)
                if mapped != .unknown { return mapped }
            }
            if let s = aff.databaseSpecific?.severity, !s.isEmpty {
                let mapped = VulnSeverity.fromString(s)
                if mapped != .unknown { return mapped }
            }
        }
        // 2) A CVSS vector string sometimes encodes nothing we can bucket
        //    without a calculator; if a numeric-looking score is present in the
        //    score field, use it.
        for sev in vuln.severity ?? [] {
            if let score = sev.score, let value = Double(score) {
                return VulnSeverity.fromCVSSScore(value)
            }
        }
        return .unknown
    }

    nonisolated private static func cveID(from vuln: OSVVuln) -> String? {
        if vuln.id.hasPrefix("CVE-") { return vuln.id }
        return (vuln.aliases ?? []).first { $0.hasPrefix("CVE-") }
    }

    nonisolated private static func referenceURL(from vuln: OSVVuln) -> String? {
        // Prefer an ADVISORY/WEB reference; else the first reference; else the
        // canonical OSV page for the id.
        let refs = vuln.references ?? []
        if let advisory = refs.first(where: { ($0.type ?? "").uppercased() == "ADVISORY" }),
           let u = advisory.url { return u }
        if let web = refs.first(where: { ($0.type ?? "").uppercased() == "WEB" }),
           let u = web.url { return u }
        if let first = refs.first, let u = first.url { return u }
        return "https://osv.dev/vulnerability/\(vuln.id)"
    }

    // Query OSV for a single package and return its result. Network errors,
    // decode errors, and non-2xx responses are folded into `scanError` so the
    // caller can show an error row rather than throwing.
    func scanPackageVulnerabilities(target: VulnScanTarget) async -> PackageVulnerabilityResult {
        // No repo => honestly "not checked", never "clean".
        guard let repo = target.repoURL else {
            return PackageVulnerabilityResult(
                kind: target.kind, packageName: target.name,
                installedVersion: target.version, repoURL: nil,
                vulns: [], scanError: nil
            )
        }

        let body: [String: Any] = [
            "package": ["name": repo, "ecosystem": "GIT"],
            "version": target.version
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return PackageVulnerabilityResult(
                kind: target.kind, packageName: target.name,
                installedVersion: target.version, repoURL: repo,
                vulns: [], scanError: "Could not build request"
            )
        }

        var request = URLRequest(url: URL(string: "https://api.osv.dev/v1/query")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return PackageVulnerabilityResult(
                    kind: target.kind, packageName: target.name,
                    installedVersion: target.version, repoURL: repo,
                    vulns: [], scanError: "OSV returned HTTP \(http.statusCode)"
                )
            }
            let decoded = try JSONDecoder().decode(OSVResponse.self, from: data)
            let vulns: [KnownVulnerability] = (decoded.vulns ?? []).map { v in
                let summary = v.summary
                    ?? v.details?.split(separator: "\n").first.map(String.init)
                    ?? v.id
                return KnownVulnerability(
                    id: v.id,
                    cveID: Self.cveID(from: v),
                    summary: summary,
                    severity: Self.severity(from: v),
                    referenceURL: Self.referenceURL(from: v)
                )
            }
            return PackageVulnerabilityResult(
                kind: target.kind, packageName: target.name,
                installedVersion: target.version, repoURL: repo,
                vulns: vulns, scanError: nil
            )
        } catch {
            return PackageVulnerabilityResult(
                kind: target.kind, packageName: target.name,
                installedVersion: target.version, repoURL: repo,
                vulns: [], scanError: error.localizedDescription
            )
        }
    }


    // Absolute path to Homebrew's download cache (e.g.
    // /Users/<you>/Library/Caches/Homebrew). Trimmed of trailing newline.
    func cachePath() async throws -> String {
        let raw = try await collect(["--cache"])
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Taps

    // Names of every tap the user has added, from `brew tap` (no args). This is
    // the short list of source repositories (e.g. "yuzeguitarist/deck") — NOT
    // the full catalog. One name per line.
    func listTapNames() async throws -> [String] {
        let raw = try await collect(["tap"])
        return raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // Decoded info for every installed tap: identity, remote, last commit, and
    // the formula/cask tokens it provides. Uses `brew tap-info --installed
    // --json`, which returns one object per tapped repository.
    func tapInfos() async throws -> [Tap] {
        let raw = try await collect(["tap-info", "--installed", "--json"])
        guard let data = raw.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode([BrewTapInfo].self, from: data)
        return decoded.map { $0.toTap() }
    }

    // Add a tap (e.g. "user/repo"). Captures brew's combined output + exit
    // status so the UI can report the precise result, mirroring untap/trustTap
    // (which already use this TapActionResult pattern).
    func addTap(_ name: String) async -> TapActionResult {
        return await runBrewActionCapturingOutput(["tap", name])
    }

    // Human-readable total size of Homebrew's download cache (e.g. "55M").
    // Returns "0B" when the cache directory doesn't exist yet. This is the
    // before/after number shown around a Cache Cleanup run.
    func cacheSize() async throws -> String {
        let path = try await cachePath()
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return "0B" }
        // `du -sh` prints "<size>\t<path>"; take the leading size token.
        //
        // Run it through the timeout-protected runner (hard-kills a hung `du`
        // after the deadline) so a slow/stuck cache measurement can never leave
        // the Maintenance card pinned on "measuring…" indefinitely. A timeout or
        // non-zero exit yields a clear, non-hanging result instead.
        let (out, status) = try await runExecutableWithStatus("/usr/bin/du", ["-sh", path], timeout: 20)
        guard status == 0 else { return "—" }
        let size = out.split(separator: "\t").first.map(String.init)
            ?? out.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            ?? "0B"
        return size.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A single parsed brew-doctor finding.
    nonisolated struct DoctorFinding: Identifiable, Sendable, Hashable {
        let id = UUID()
        let title: String   // first line of the warning
        let detail: String  // remaining lines, joined
        // How many times brew doctor emitted this identical warning. brew can
        // repeat the same warning several times (e.g. one deprecated cask syntax
        // line printed once per dependency walk). We collapse identical
        // findings into one and surface the repeat count instead of stacking
        // duplicate cards. 1 = appeared once.
        var occurrences: Int = 1
        // When this finding is the "taps are not trusted" warning, we break the
        // raw brew text into structured per-tap info (rendered as a list of
        // cards) plus a short, plain-language explanation in `detail`. Empty for
        // every other kind of finding, which keeps using `title` + `detail`.
        var untrustedTaps: [UntrustedTap] = []
    }

    // One Homebrew tap that brew no longer trusts by default. We enrich the bare
    // tap name from `brew doctor` with what we can read off disk so the user can
    // judge it: when it was tapped, when it last updated, and what it provides.
    nonisolated struct UntrustedTap: Identifiable, Sendable, Hashable {
        var id: String { name }
        let name: String            // "<user>/<tap>", e.g. "yuzeguitarist/deck"
        let path: String?           // tap repo directory, if resolved
        let tappedDate: Date?       // when the tap was added locally (dir creation)
        let lastUpdated: Date?      // last git commit date in the tap repo
        let caskCount: Int          // number of casks the tap provides
        let formulaCount: Int       // number of formulae the tap provides
        let sampleNames: [String]   // a few cask/formula names for context
    }

    // Result of a parsed `brew doctor` run: whether the system is clean, plus
    // the individual warnings broken out so the UI can list them with status
    // chips instead of a wall of text.
    nonisolated struct DoctorReport: Sendable {
        let isClean: Bool
        // True when brew doctor printed "Your system is ready to brew." — brew
        // says this even alongside non-fatal warnings (e.g. a tap's deprecated
        // cask syntax). Lets the UI reassure the user the system still works
        // while still listing the warnings.
        var systemReady: Bool = false
        let findings: [DoctorFinding]
    }

    // Runs `brew doctor` and parses it into structured findings. `brew doctor`
    // emits "Your system is ready to brew." when clean; otherwise it prints an
    // intro line ("Please note that these warnings are just used...") followed
    // by one or more "Warning: <title>" blocks, each with indented/continuation
    // detail lines until the next blank line or next "Warning:".
    func doctorReport() async -> DoctorReport {
        let output: String
        let exitStatus: Int32
        do {
            // brew doctor exits non-zero when it finds warnings, so we can't use
            // `collect` (which throws on non-zero). Read directly instead, and
            // keep the exit status as the authoritative clean/dirty signal.
            (output, exitStatus) = try await runBrewAllowingFailure(["doctor"])
        } catch {
            return DoctorReport(isClean: false,
                                findings: [DoctorFinding(title: "Could not run brew doctor",
                                                         detail: error.localizedDescription)])
        }

        // NOTE: brew doctor can print BOTH "Warning:" blocks AND a closing
        // "Your system is ready to brew." line in the same run — the non-fatal
        // style warnings (e.g. a tap using deprecated `depends_on macos:`
        // syntax) don't stop brew from declaring the system "ready". So we must
        // NOT early-return on that string: doing so discarded real warnings.
        // Instead we always parse the warnings below, then decide clean/dirty
        // from whether any warnings were actually found.
        var findings: [DoctorFinding] = []
        var currentTitle: String? = nil
        var currentDetail: [String] = []

        func flush() {
            if let title = currentTitle {
                findings.append(DoctorFinding(
                    title: title,
                    detail: currentDetail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            currentTitle = nil
            currentDetail = []
        }

        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Warning:") {
                flush()
                currentTitle = String(line.dropFirst("Warning:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("please note that these warnings") {
                // Skip brew's standard intro paragraph.
                continue
            } else if line.lowercased().contains("your system is ready to brew") {
                // Skip brew's closing summary line — it can appear after the
                // warning blocks and must not be glued onto the last finding.
                flush()
                continue
            } else if currentTitle != nil, !line.isEmpty {
                currentDetail.append(line)
            }
        }
        flush()

        // Post-process: the "taps are not trusted" warning arrives as one long
        // block of brew instructions. Split it into structured per-tap cards and
        // a short, plain explanation so the UI can render two clean boxes
        // instead of a wall of shell commands.
        var processed: [DoctorFinding] = []
        for finding in findings {
            if finding.title.lowercased().contains("taps are not trusted")
                || finding.title.lowercased().contains("tap is not trusted") {
                let tapNames = Self.parseUntrustedTapNames(from: finding.detail)
                let taps = await untrustedTapInfo(names: tapNames)
                processed.append(DoctorFinding(
                    title: taps.count == 1 ? "1 tap is not trusted"
                                           : "\(taps.count) taps are not trusted",
                    detail: Self.untrustedTapExplanation,
                    untrustedTaps: taps
                ))
            } else {
                processed.append(finding)
            }
        }

        // Collapse identical warnings. brew doctor can print the exact same
        // warning several times in one run (e.g. the deprecated `depends_on
        // macos:` cask-syntax warning is emitted once per resolution pass), and
        // listing the same card three times is just noise. We key on title +
        // detail, keep first-seen order, and bump `occurrences` so the UI can
        // show an "×N" badge on a single card instead of stacking duplicates.
        // Untrusted-taps findings are never merged (each is already unique).
        var deduped: [DoctorFinding] = []
        var indexByKey: [String: Int] = [:]
        for finding in processed {
            if !finding.untrustedTaps.isEmpty {
                deduped.append(finding)
                continue
            }
            let key = finding.title + "\u{1f}" + finding.detail
            if let i = indexByKey[key] {
                deduped[i].occurrences += 1
            } else {
                indexByKey[key] = deduped.count
                deduped.append(finding)
            }
        }

        // No warnings parsed. Decide clean vs. error:
        //  • If brew said "ready to brew" or exited 0, the system is genuinely
        //    clean — report clean.
        //  • Otherwise brew exited non-zero with output we couldn't parse
        //    (a format change or truncated output). Never show a false "all
        //    clear": surface the raw output so the real problem is visible.
        if deduped.isEmpty {
            let lower = output.lowercased()
            if exitStatus == 0 || lower.contains("your system is ready to brew") {
                return DoctorReport(isClean: true, systemReady: true, findings: [])
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return DoctorReport(
                isClean: false,
                findings: [DoctorFinding(
                    title: "brew doctor reported issues",
                    detail: trimmed.isEmpty
                        ? "brew doctor exited with status \(exitStatus) but produced no readable output."
                        : trimmed
                )]
            )
        }

        // Warnings were found — system is not clean regardless of any trailing
        // "ready to brew" line brew may also have printed. We DO carry the
        // "ready" signal so the UI can reassure the user the warnings are
        // non-fatal (brew itself said the system is ready).
        let ready = output.lowercased().contains("your system is ready to brew")
        return DoctorReport(isClean: false, systemReady: ready, findings: deduped)
    }

    // A tap name in brew's output looks like "<user>/<tap>" — lowercase letters,
    // digits, dashes around a single slash, no spaces. brew lists each untrusted
    // tap on its own line before the instructional paragraph, so we pull those
    // standalone tokens and ignore the command examples (which contain spaces,
    // angle brackets, or extra slashes).
    nonisolated static func parseUntrustedTapNames(from detail: String) -> [String] {
        var names: [String] = []
        for raw in detail.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" "), !line.contains("<"),
                  !line.contains("="), !line.contains("`") else { continue }
            let parts = line.split(separator: "/")
            guard parts.count == 2 else { continue }
            let valid = parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            }
            if valid, !names.contains(line) { names.append(line) }
        }
        return names
    }

    // A short, plain-language version of brew's trust message. The full command
    // reference lives in the UI's expandable section, not here.
    nonisolated static let untrustedTapExplanation = """
    Homebrew is moving to a model where third-party taps must be explicitly trusted. \
    Once trust checks become the default (Homebrew 6.0 or 5.2, whichever comes first), \
    formulae, casks, and commands from an untrusted tap are simply ignored — not loaded — \
    unless you trust it. Nothing is uninstalled or deleted: apps you already installed from \
    the tap keep running, but Homebrew stops tracking and updating them until you trust the tap again. \
    These taps still work today; this is an early heads-up so nothing silently goes stale later.

    Trust (“brew trust”): keeps the tap and tells Homebrew to keep loading and updating it. \
    This setting is sticky — it stays until you remove it and is not re-checked on a schedule, \
    so the tap’s apps keep getting updates as before.

    Remove Tap (“brew untap”): deletes only the tap’s install recipes, not your installed apps. \
    Those apps stay on your Mac and keep running, but Homebrew can no longer update, track, or \
    cleanly uninstall them. Only do this if you no longer need anything from the tap. Homebrew \
    refuses if packages are still installed from it, and you can always re-add it later with “brew tap”.

    Good to know: if a tap or cask goes away and later returns to its source, Homebrew picks it \
    back up automatically on the next update — you don’t have to babysit it. The only time you must \
    act again is if you removed the tap yourself, or if the app comes back under a different name.
    """

    // Enriches bare tap names with what we can read off disk: the tap repo path,
    // when it was added locally, its last git update, and what it provides. Any
    // field we can't resolve is left nil/zero rather than failing the whole row.
    func untrustedTapInfo(names: [String]) async -> [UntrustedTap] {
        let repo = (try? await collect(["--repository"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        var result: [UntrustedTap] = []
        for name in names {
            let parts = name.split(separator: "/")
            var path: String? = nil
            var tappedDate: Date? = nil
            var caskCount = 0
            var formulaCount = 0
            var sampleNames: [String] = []
            if let repo, parts.count == 2 {
                let dir = "\(repo)/Library/Taps/\(parts[0])/homebrew-\(parts[1])"
                if fm.fileExists(atPath: dir) {
                    path = dir
                    if let attrs = try? fm.attributesOfItem(atPath: dir) {
                        tappedDate = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
                    }
                    let casks = (try? fm.contentsOfDirectory(atPath: "\(dir)/Casks"))?
                        .filter { $0.hasSuffix(".rb") } ?? []
                    let formulae = (try? fm.contentsOfDirectory(atPath: "\(dir)/Formula"))?
                        .filter { $0.hasSuffix(".rb") } ?? []
                    caskCount = casks.count
                    formulaCount = formulae.count
                    sampleNames = (casks + formulae)
                        .map { String($0.dropLast(3)) }
                        .sorted()
                        .prefix(4)
                        .map { $0 }
                }
            }
            let lastUpdated = await tapLastUpdated(path: path)
            result.append(UntrustedTap(
                name: name,
                path: path,
                tappedDate: tappedDate,
                lastUpdated: lastUpdated,
                caskCount: caskCount,
                formulaCount: formulaCount,
                sampleNames: sampleNames
            ))
        }
        return result
    }

    // Last git commit date in a tap repo, via `git -C <dir> log -1 --format=%ct`.
    // Returns nil if the path is missing or git can't read it.
    private func tapLastUpdated(path: String?) async -> Date? {
        guard let path else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "log", "-1", "--format=%ct"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let epoch = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    // Like `collect`, but returns output even on a non-zero exit (brew doctor
    // exits 1 when warnings exist). Only throws if the process can't launch.
    private func runBrewAllowingFailure(_ arguments: [String], timeout: TimeInterval = 90) async throws -> (output: String, status: Int32) {
        let path = try brewPath
        // Route through the timeout-protected runner so a wedged brew command
        // (e.g. `brew doctor` stalling on a slow git fetch / network hiccup)
        // is hard-killed at the deadline instead of blocking forever on
        // waitUntilExit() — which previously left the Maintenance Doctor card
        // spinning on "Running brew doctor…" with no way out. We return BOTH the
        // captured output AND the exit status: brew doctor exits 0 only when the
        // system is clean and non-zero when it finds warnings, so the status is
        // the authoritative clean/dirty signal (more reliable than scraping the
        // output for a "ready to brew" string, which changes across versions).
        let (out, status) = try await runExecutableWithStatus(path, arguments, timeout: timeout)
        return (BrewCLIService.stripANSI(out), status)
    }

    // MARK: - Quarantine (Gatekeeper) management

    // One file carrying the com.apple.quarantine extended attribute. Surfaced
    // in the Maintenance "Remove Quarantine" sheet so the user can clear the
    // Gatekeeper flag that triggers the "downloaded from the internet" prompt.
    nonisolated struct QuarantinedItem: Identifiable, Sendable, Hashable {
        var id: String { path }
        let path: String          // absolute path to the quarantined file
        let displayName: String   // last path component (e.g. "Foo.app")
    }

    // Scans /Applications and ~/Applications for apps that still carry the
    // com.apple.quarantine extended attribute.
    //
    // This used to shell out to `xattr -r -l <dir>` and text-parse the output,
    // which missed apps for several reasons: `-r` recurses into every bundle
    // and emits brittle hex-dump continuation lines, the `": "` split breaks on
    // paths containing spaces/colons, and a permission failure (no Full Disk
    // Access) silently looked identical to "nothing found". We catch the
    // apps we'd otherwise miss by checking the bundle directly.
    //
    // The rewrite enumerates only the TOP-LEVEL entries of each apps folder and
    // asks `xattr` about each bundle directly — the same shell-out pattern the
    // rest of this service already uses for brew/du. `xattr -p <attr> <path>`
    // exits 0 only when the attribute is present, so we don't have to parse any
    // output: the exit status is the answer.
    //   1. Resolve symlinks first — /Applications is an APFS firmlink and apps
    //      can themselves be symlinks; we want the real bundle path.
    //   2. Probe each top-level .app concurrently for speed.
    func scanQuarantinedItems() async -> [QuarantinedItem] {
        // Gather every top-level .app bundle across the user's enabled apps
        // folders (/Applications and/or ~/Applications, per the app-wide
        // AppLocationSettings toggle), de-duped by resolved path so an app
        // symlinked into both folders is one entry.
        let candidates = AppLocationSettings.installedAppBundles()

        // Probe each candidate concurrently.
        let hits = await withTaskGroup(of: QuarantinedItem?.self) { group in
            for candidate in candidates {
                group.addTask {
                    await self.isQuarantined(path: candidate.path)
                        ? QuarantinedItem(path: candidate.path, displayName: candidate.name)
                        : nil
                }
            }
            var found: [QuarantinedItem] = []
            for await item in group {
                if let item { found.append(item) }
            }
            return found
        }

        return hits.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // True when the bundle carries the com.apple.quarantine attribute, decided
    // by `xattr -p`'s exit status (0 = present, non-zero = missing). This uses
    // the same Process shell-out style as the rest of the service — no C-level
    // getxattr/errno handling to maintain. We can't reuse `runExecutable` here
    // because it ignores the exit code; for this probe the exit code IS the
    // answer, so we run a tiny Process and read `terminationStatus` directly.
    private func isQuarantined(path: String) async -> Bool {
        // Route through the non-blocking GCD-queue runner so this never blocks
        // a Swift-concurrency cooperative thread. The old version blocked a
        // cooperative thread on process.waitUntilExit() inside Task.detached;
        // when scanQuarantinedItems fanned out across every installed app (and
        // especially while a batch un-quarantine was also in flight) that
        // starved the small cooperative pool and wedged the whole operation —
        // the UI spun forever even though the xattr work had finished. A short
        // hard timeout means a single misbehaving probe can't stall the rest.
        do {
            let (_, status) = try await runExecutableWithStatus(
                "/usr/bin/xattr",
                ["-p", "com.apple.quarantine", path],
                timeout: 5
            )
            return status == 0
        } catch {
            return false
        }
    }

    // Removes the com.apple.quarantine attribute from a single path via
    // `xattr -r -d com.apple.quarantine <path>`. `-r` recurses so clearing a
    // bundle root also clears any inner files that inherited the flag. A path
    // that no longer has the attribute (already cleared) is treated as success.
    func removeQuarantine(at path: String) async -> Bool {
        // Use the non-blocking GCD-queue runner (not runExecutable, which blocks
        // a cooperative thread on readDataToEndOfFile). `xattr -r -d` recurses
        // through every nested file of the .app bundle, so on a large app this
        // can take a while and emit a lot of output; doing that on a cooperative
        // thread — across many selected apps at once — starved the pool and hung
        // the batch "Remove Quarantine from Selected" action even though the
        // flag was actually being cleared. A generous hard timeout guards
        // against any single bundle stalling the batch.
        //
        // xattr exits non-zero if the attribute is already absent on some inner
        // file ("No such xattr"); since `-r` may hit files with and without the
        // flag, a non-zero status does NOT reliably mean failure. We treat the
        // call as successful as long as it ran to completion without timing out;
        // the caller re-scans afterward to confirm what actually remains.
        do {
            _ = try await runExecutableWithStatus(
                "/usr/bin/xattr",
                ["-r", "-d", "com.apple.quarantine", path],
                timeout: 30
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Tap trust / untap

    // Outcome of a `brew trust` or `brew untap` run. We capture brew's own
    // combined output so a failure can show the user exactly what went wrong
    // (network issue, unknown tap, etc.) rather than a bare "it failed".
    nonisolated struct TapActionResult: Sendable {
        let success: Bool
        let message: String   // brew's output, trimmed; empty on a clean success
    }

    // Trusts a whole tap so Homebrew keeps using its formulae and casks once
    // tap-trust checks become the default. Equivalent to `brew trust user/repo`.
    func trustTap(_ name: String) async -> TapActionResult {
        return await runBrewActionCapturingOutput(["trust", name])
    }

    // Removes a tap entirely (`brew untap user/repo`). Use when the user no
    // longer wants the tap at all rather than trusting it. brew refuses to
    // untap if installed packages still depend on it; that refusal is surfaced
    // verbatim in the result message.
    func untap(_ name: String) async -> TapActionResult {
        return await runBrewActionCapturingOutput(["untap", name])
    }

    // Runs a brew subcommand, capturing combined stdout+stderr and the exit
    // status so we can report a precise success/failure with brew's own words.
    private func runBrewActionCapturingOutput(_ arguments: [String]) async -> TapActionResult {
        let path: String
        do {
            path = try brewPath
        } catch {
            return TapActionResult(success: false, message: error.localizedDescription)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return TapActionResult(success: false, message: error.localizedDescription)
        }
        let readHandle = pipe.fileHandleForReading
        let data = await Task.detached(priority: .utility) {
            readHandle.readDataToEndOfFile()
        }.value
        process.waitUntilExit()
        let raw = BrewCLIService.stripANSI(String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TapActionResult(success: process.terminationStatus == 0, message: raw)
    }

    // MARK: - Adopt (bring an existing app under Homebrew management)

    // An app already sitting in /Applications (or ~/Applications) that is NOT
    // managed by Homebrew but that we can confidently match to a known cask.
    // "Adopting" runs `brew install --cask --adopt <token>` so Homebrew takes
    // ownership of the existing bundle in place (no re-download of the app),
    // after which it shows up in the Installed list and gets update tracking.
    nonisolated struct AdoptCandidate: Identifiable, Sendable, Hashable {
        var id: String { path }
        let path: String           // absolute path to the .app bundle
        let appName: String        // bundle name without ".app" (e.g. "Google Chrome")
        let suggestedToken: String // best-guess cask token (e.g. "google-chrome")
        // Extra context so the user can decide before adopting. All optional —
        // we surface what we can read and omit what we can't.
        let installedVersion: String?  // CFBundleShortVersionString from the bundle
        let installDate: Date?         // bundle's file creation date (best-effort)
        let latestVersion: String?     // the cask's current version from the catalog
    }

    // Reads the human version (CFBundleShortVersionString, falling back to
    // CFBundleVersion) from an .app bundle's Info.plist. Returns nil if the
    // bundle can't be read.
    nonisolated static func bundleVersion(atPath path: String) -> String? {
        guard let bundle = Bundle(path: path) else { return nil }
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let v = short ?? build
        guard let v, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return v
    }

    // Best-effort install date: the bundle's file creation date. Apps copied
    // into /Applications keep the copy date here, which is a reasonable proxy
    // for "when did I install this". Returns nil if unavailable.
    nonisolated static func bundleInstallDate(atPath path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.creationDate] as? Date
    }

    // Normalizes a human label (app name or cask name) into a comparison key:
    // lowercased, with anything that isn't a letter or digit removed. This lets
    // "Google Chrome", "google-chrome", and "GoogleChrome" all collapse to the
    // same key "googlechrome" for a high-confidence match.
    nonisolated static func adoptMatchKey(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
    }

    // Strips a trailing macOS "collision counter" from an app's display name.
    // When a second copy of an app lands in /Applications (e.g. you already have
    // a Homebrew-installed "DuckDuckGo.app" and then install the App Store
    // build), the Finder/installer renames the newcomer "DuckDuckGo 2.app" so
    // the two don't overwrite each other. That trailing " 2" otherwise leaks
    // into adoptMatchKey and pushes the two copies into different buckets, so
    // duplicate detection never sees them as the same app. We remove a trailing
    // space + 1-3 digits (" 2" ... " 999") so both copies normalize to the same
    // base key. Names that legitimately end in a number but have no sibling copy
    // are unaffected: a lone bundle still can't form a 2+ duplicate group.
    nonisolated static func baseAppName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: "\\s\\d{1,3}$", options: .regularExpression) else {
            return trimmed
        }
        return String(trimmed[trimmed.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
    }

    // Scans the user's enabled Applications folders for .app bundles that are
    // NOT already managed by Homebrew, and matches each — high-confidence only —
    // against the known cask catalog. Matching is exact on the normalized key:
    // the app's name (minus ".app") must equal a cask's display name OR its
    // token, after normalization. No fuzzy/substring matching, so we don't
    // suggest the wrong cask.
    //
    // - Parameters:
    //   - casks: the full cask catalog (token + human names) to match against.
    //   - managedTokens: tokens Homebrew already manages (from the Installed
    //     list). Apps matching one of these are skipped — they're already
    //     adopted, so there's nothing to do.
    //   - hiddenTokens: tokens the user chose to hide from Adopt; skipped.
    func scanAdoptableApps(
        casks: [CaskMetadata],
        managedTokens: Set<String>,
        hiddenTokens: Set<String>
    ) async -> [AdoptCandidate] {
        // Build a normalized-key -> token lookup from the catalog. We index both
        // the token itself and every human name so either spelling matches.
        // First-write wins so a token's own spelling isn't clobbered by a name
        // collision from another cask.
        var keyToToken: [String: String] = [:]
        var tokenToVersion: [String: String] = [:]
        for cask in casks where !cask.deprecated {
            let tokenKey = BrewCLIService.adoptMatchKey(cask.token)
            if keyToToken[tokenKey] == nil { keyToToken[tokenKey] = cask.token }
            for name in cask.name {
                let nameKey = BrewCLIService.adoptMatchKey(name)
                if !nameKey.isEmpty, keyToToken[nameKey] == nil {
                    keyToToken[nameKey] = cask.token
                }
            }
            if let v = cask.version { tokenToVersion[cask.token] = v }
        }

        let bundles = AppLocationSettings.installedAppBundles()
        var results: [AdoptCandidate] = []
        var seenTokens = Set<String>()
        for bundle in bundles {
            // Strip the trailing ".app" to get the human app name.
            let appName = bundle.name.hasSuffix(".app")
                ? String(bundle.name.dropLast(4))
                : bundle.name
            let key = BrewCLIService.adoptMatchKey(appName)
            guard !key.isEmpty, let token = keyToToken[key] else { continue }
            // Skip apps Homebrew already manages or that the user hid, and avoid
            // suggesting the same token twice (two bundles -> one cask).
            guard !managedTokens.contains(token),
                  !hiddenTokens.contains(token),
                  seenTokens.insert(token).inserted else { continue }
            results.append(AdoptCandidate(
                path: bundle.path,
                appName: appName,
                suggestedToken: token,
                installedVersion: BrewCLIService.bundleVersion(atPath: bundle.path),
                installDate: BrewCLIService.bundleInstallDate(atPath: bundle.path),
                latestVersion: tokenToVersion[token]
            ))
        }
        return results.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    // Adopts an existing app into Homebrew via `brew install --cask --adopt`.
    // Homebrew takes ownership of the bundle already on disk instead of
    // re-downloading it. When `force` is true we add `--force`, which reinstalls
    // over a version mismatch (brew's "adopt completed but the app was not
    // updated" / "Cask <token> is already installed" cases) — our fallback
    // for when a plain adopt reports a mismatch.
    func adoptCask(token: String, force: Bool = false) async -> AsyncStream<String> {
        var args = ["install", "--cask", "--adopt"]
        if force { args.append("--force") }
        args.append(token)
        do {
            return try await run(args)
        } catch {
            return AsyncStream<String> { continuation in
                continuation.yield("Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    // MARK: - Duplicates (same app/tool installed more than once)

    // True when an .app bundle was installed from the Mac App Store. MAS apps
    // carry a receipt at Contents/_MASReceipt/receipt; its presence is the
    // canonical, dependency-free signal (no `mas` CLI required).
    nonisolated static func isAppStoreApp(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString)
            .appendingPathComponent("Contents/_MASReceipt/receipt"))
    }

    // Resolves the set of physical /Applications paths that Homebrew actually
    // manages for a given cask token. The Caskroom stores each installed cask
    // under <prefix>/Caskroom/<token>/<version>/ and the app artifact there is a
    // SYMLINK back to the real bundle Homebrew put in /Applications, e.g.
    //   /opt/homebrew/Caskroom/brave-browser/1.91.171.0/Brave Browser.app
    //     -> /Applications/Brave Browser.app
    // Following those symlinks tells us exactly which on-disk copy brew owns.
    // This is what lets us tell a Homebrew-installed copy apart from a second,
    // web-downloaded copy of the SAME app sitting next to it (e.g. "Brave
    // Browser 2.app"): only the symlink target is Homebrew; the other copy is a
    // manual install. Returns standardized absolute paths (no trailing slash).
    nonisolated static func caskManagedAppPaths(token: String, brewPrefix: String) -> Set<String> {
        let fm = FileManager.default
        let caskDir = (brewPrefix as NSString)
            .appendingPathComponent("Caskroom")
        let tokenDir = (caskDir as NSString).appendingPathComponent(token)
        guard fm.fileExists(atPath: tokenDir) else { return [] }
        var resolved = Set<String>()
        // Each version is its own subdirectory; the ".app" entries inside are the
        // symlinks we care about. We skip the dotfiles (.metadata, receipts).
        let versions = (try? fm.contentsOfDirectory(atPath: tokenDir)) ?? []
        for v in versions where !v.hasPrefix(".") {
            let vDir = (tokenDir as NSString).appendingPathComponent(v)
            let entries = (try? fm.contentsOfDirectory(atPath: vDir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let link = (vDir as NSString).appendingPathComponent(entry)
                // Prefer the symlink destination; fall back to the canonicalized
                // path if it's somehow a real bundle instead of a link.
                if let dest = try? fm.destinationOfSymbolicLink(atPath: link) {
                    let abs = (dest as NSString).isAbsolutePath
                        ? dest
                        : (vDir as NSString).appendingPathComponent(dest)
                    resolved.insert((abs as NSString).standardizingPath)
                } else {
                    resolved.insert((link as NSString).standardizingPath)
                }
            }
        }
        return resolved
    }

    // Every top-level .app across the enabled apps folders WITHOUT de-duping by
    // resolved path — unlike AppLocationSettings.installedAppBundles(), which
    // collapses copies. Duplicate detection needs each physical copy, so we
    // enumerate the raw entries here and only skip exact-duplicate path strings.
    nonisolated static func rawAppBundles() -> [(path: String, name: String)] {
        let fm = FileManager.default
        var results: [(path: String, name: String)] = []
        var seenPaths = Set<String>()
        for dir in AppLocationSettings.searchDirectories {
            guard fm.fileExists(atPath: dir) else { continue }
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let full = (dir as NSString).appendingPathComponent(entry)
                guard seenPaths.insert(full).inserted else { continue }
                results.append((path: full, name: entry))
            }
        }
        return results
    }

    // Best-effort on-disk size of a bundle in bytes via `du -sk` (kilobytes,
    // portable). Returns nil if it can't be measured.
    func bundleSizeBytes(atPath path: String) async -> Int64? {
        // Timeout-protected so a hung `du` on a single bundle can't stall the
        // caller indefinitely (returns nil on timeout/failure).
        guard let (out, _) = try? await runExecutableWithStatus("/usr/bin/du", ["-sk", path], timeout: 15) else { return nil }
        let token = out.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
        guard let kb = token.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    // Finds every genuine duplicate: an app/tool installed via two+ sources or
    // sitting at two+ on-disk paths at once. See DuplicateGroup.swift for the
    // three kinds. Matching uses the same normalized key as Adopt so spelling
    // variants collapse together.
    //
    // - Parameters:
    //   - casks: the cask catalog (for app-artifact names + versions).
    //   - installedCaskTokens: tokens brew manages as casks.
    //   - installedFormulaTokens: tokens brew manages as formulae.
    func scanDuplicates(
        casks: [CaskMetadata],
        installedCaskTokens: Set<String>,
        installedFormulaTokens: Set<String>
    ) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []

        // Homebrew install prefix, used to locate the Caskroom so we can tell
        // which physical /Applications copy brew actually manages (vs. a second,
        // manually-downloaded copy of the same app).
        let brewPrefix = (try? await collect(["--prefix"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "/opt/homebrew"

        // --- Index the catalog: normalized key -> (token, appArtifactName) ---
        // We index the cask token, every human name, AND the .app artifact name
        // (minus ".app") so an installed bundle can be tied back to its cask.
        var keyToCaskToken: [String: String] = [:]
        var caskVersion: [String: String] = [:]
        for cask in casks {
            let tk = BrewCLIService.adoptMatchKey(cask.token)
            if keyToCaskToken[tk] == nil { keyToCaskToken[tk] = cask.token }
            for name in cask.name {
                let nk = BrewCLIService.adoptMatchKey(name)
                if !nk.isEmpty, keyToCaskToken[nk] == nil { keyToCaskToken[nk] = cask.token }
            }
            if let v = cask.version { caskVersion[cask.token] = v }
        }

        // --- (A) On-disk scan: group raw bundles by normalized app name ---
        let bundles = BrewCLIService.rawAppBundles()
        var byKey: [String: [(path: String, name: String, isMAS: Bool)]] = [:]
        for b in bundles {
            let appName = b.name.hasSuffix(".app") ? String(b.name.dropLast(4)) : b.name
            // Bucket on the collision-stripped base name so "DuckDuckGo" and
            // "DuckDuckGo 2" (the App-Store-vs-Homebrew case) land together.
            let key = BrewCLIService.adoptMatchKey(BrewCLIService.baseAppName(appName))
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append((b.path, appName,
                                            BrewCLIService.isAppStoreApp(atPath: b.path)))
        }

        // Helper: build a DuplicateInstall (reads version + size) for a bundle.
        func diskInstall(path: String, source: DuplicateSource) async -> DuplicateInstall {
            DuplicateInstall(
                source: source,
                path: path,
                version: BrewCLIService.bundleVersion(atPath: path),
                sizeBytes: await self.bundleSizeBytes(atPath: path)
            )
        }

        for (key, copies) in byKey {
            let displayName = copies.first?.name ?? key
            // Determine the cask token (if any) that this app maps to, and
            // whether brew currently manages it as a cask.
            let caskToken = keyToCaskToken[key]
            let brewManaged = caskToken.map { installedCaskTokens.contains($0) } ?? false

            // (A1) Multiple physical copies of the same app on disk.
            if copies.count >= 2 {
                // When brew manages this cask, figure out WHICH physical copy it
                // owns by resolving the Caskroom symlink(s). Only that exact path
                // is Homebrew; any other non-MAS copy is a separate manual /
                // web-downloaded install and must be labeled accordingly.
                // (Previously every non-MAS copy was tagged Homebrew, so a
                // hand-downloaded "Brave Browser 2.app" showed up as a second
                // "Homebrew" entry alongside the real cask install.)
                let managedPaths: Set<String> = (brewManaged ? caskToken : nil)
                    .map { BrewCLIService.caskManagedAppPaths(token: $0, brewPrefix: brewPrefix) }
                    ?? []
                var installs: [DuplicateInstall] = []
                for c in copies {
                    let source: DuplicateSource
                    if c.isMAS {
                        source = .appStore
                    } else if let t = caskToken,
                              managedPaths.contains((c.path as NSString).standardizingPath) {
                        // This is the exact bundle the cask symlinks to.
                        source = .homebrewCask(t)
                    } else {
                        // Non-MAS copy that brew does not own -> manual install.
                        source = .manualOnDisk
                    }
                    installs.append(await diskInstall(path: c.path, source: source))
                }
                groups.append(DuplicateGroup(kind: .multipleCopies, key: key,
                                             displayName: displayName, installs: installs))
                continue   // a multi-copy group already captures this app
            }

            // (A2) Single copy on disk, but it's an App Store app that brew ALSO
            // manages as a cask → App Store vs Homebrew duplicate.
            if let only = copies.first, only.isMAS, brewManaged, let t = caskToken {
                let masInstall = await diskInstall(path: only.path, source: .appStore)
                // The brew cask points at the same bundle; show it as the brew
                // side with the cask's catalog version for context.
                let brewInstall = DuplicateInstall(
                    source: .homebrewCask(t),
                    path: only.path,
                    version: caskVersion[t],
                    sizeBytes: masInstall.sizeBytes
                )
                groups.append(DuplicateGroup(kind: .appStoreVsHomebrew, key: key,
                                             displayName: displayName,
                                             installs: [masInstall, brewInstall]))
            }
        }

        // --- (B) Formula + cask: same tool installed both ways ---
        // Match on the normalized token key so e.g. a formula and cask that
        // share a name are paired even if the raw tokens differ in punctuation.
        var formulaByKey: [String: String] = [:]
        for t in installedFormulaTokens { formulaByKey[BrewCLIService.adoptMatchKey(t)] = t }
        for caskToken in installedCaskTokens {
            let k = BrewCLIService.adoptMatchKey(caskToken)
            guard let formulaToken = formulaByKey[k] else { continue }
            groups.append(DuplicateGroup(
                kind: .formulaAndCask, key: k, displayName: caskToken,
                installs: [
                    DuplicateInstall(source: .homebrewFormula(formulaToken), path: nil,
                                     version: caskVersion[caskToken], sizeBytes: nil),
                    DuplicateInstall(source: .homebrewCask(caskToken), path: nil,
                                     version: caskVersion[caskToken], sizeBytes: nil)
                ]))
        }

        return groups.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // Removes ONE copy of a duplicate. The action depends on the source:
    //   • homebrew cask    → `brew uninstall --cask <token>`
    //   • homebrew formula → `brew uninstall --formula <token>`
    //   • manual on disk   → move the .app bundle to the Trash
    //   • App Store        → move the .app bundle to the Trash (recoverable)
    // Returns nil on success, or a user-facing error string on failure so the
    // sheet can surface exactly what went wrong (the OneDrive-style cases).
    func removeDuplicateInstall(_ install: DuplicateInstall) async -> String? {
        switch install.source {
        case .homebrewCask(let token):
            return await drainUninstall(self.uninstall(cask: token), label: token)
        case .homebrewFormula(let token):
            return await drainUninstall(self.uninstallFormula(token), label: token)
        case .manualOnDisk:
            guard let path = install.path else { return "No file path to remove." }
            return BrewCLIService.trashBundle(atPath: path)
        case .appStore:
            // Move the App Store .app to the Trash (recoverable). The user's
            // purchase stays in their Apple account, so they can re-download it
            // any time. Same Trash path as a manual on-disk copy.
            guard let path = install.path else { return "No file path to remove." }
            return BrewCLIService.trashBundle(atPath: path)
        }
    }

    // Drains an uninstall stream and inspects the output for a failure signal,
    // mirroring the adopt-summary classification. Returns nil on success or an
    // error message on failure.
    private func drainUninstall(_ stream: AsyncStream<String>, label: String) async -> String? {
        var lines: [String] = []
        for await line in stream { lines.append(line) }
        let joined = lines.joined(separator: "\n").lowercased()
        if joined.contains("error") || joined.contains("failed")
            || joined.contains("permission denied") || joined.contains("cannot") {
            let tail = lines.last(where: { $0.lowercased().contains("error") })
                ?? lines.last ?? "Uninstall failed"
            return tail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // Moves a bundle to the user's Trash via FileManager. Returns nil on success
    // or a user-facing error string. Uses trashItem (recoverable) rather than a
    // hard delete so a mistaken removal can be undone from the Trash.
    nonisolated static func trashBundle(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        // Fast path: move to Trash as the current user. This works for manual /
        // web-downloaded copies the user owns.
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return nil
        } catch {
            // App Store apps are installed by macOS as root:wheel and carry a
            // com.apple.macl access-control xattr, so a plain user-level
            // trashItem is denied with a permission error. That's NOT a brew
            // sudo case — it needs an OS-level elevated move. Fall back to an
            // AppleScript "with administrator privileges" move into ~/.Trash,
            // which triggers the native macOS authorization dialog and lands the
            // bundle in the Trash (recoverable, not a hard delete).
            if let elevatedError = trashBundleElevated(atPath: path) {
                // Elevation also failed (user cancelled the prompt, or some
                // other error). Surface a clear message.
                return elevatedError
            }
            return nil
        }
    }

    // Moves a bundle to the user's Trash using elevated privileges via
    // AppleScript's "with administrator privileges", for root-owned / TCC-
    // protected bundles (e.g. Mac App Store apps) that the current user can't
    // trash directly. macOS presents its own standard secure password dialog.
    // We move into ~/.Trash (renaming on collision) rather than hard-deleting so
    // a mistaken removal is still recoverable from the Trash. Returns nil on
    // success, a user-facing error string on failure, or a cancellation message
    // if the user dismisses the password prompt.
    nonisolated static func trashBundleElevated(atPath path: String) -> String? {
        let trashDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".Trash")
        let bundleName = (path as NSString).lastPathComponent
        // Pick a non-colliding destination name inside the Trash.
        let fm = FileManager.default
        var destName = bundleName
        if fm.fileExists(atPath: (trashDir as NSString).appendingPathComponent(destName)) {
            let base = (bundleName as NSString).deletingPathExtension
            let ext = (bundleName as NSString).pathExtension
            let stamp = Int(Date().timeIntervalSince1970)
            destName = ext.isEmpty ? "\(base) \(stamp)" : "\(base) \(stamp).\(ext)"
        }
        let dest = (trashDir as NSString).appendingPathComponent(destName)

        // Build the shell command run as admin. Single-quote both paths for the
        // shell, escaping any embedded single quotes the POSIX way ('\'').
        func shQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let shellCmd = "/bin/mv -f \(shQuote(path)) \(shQuote(dest))"

        // Escape for embedding inside an AppleScript double-quoted string.
        let asEscaped = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource =
            "do shell script \"\(asEscaped)\" with administrator privileges"

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: scriptSource) else {
            return "Couldn't prepare the elevated removal."
        }
        script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            // -128 is the standard "User canceled" AppleScript error code.
            let code = (info["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -128 {
                return "Removal cancelled — administrator password was not entered."
            }
            let msg = (info["NSAppleScriptErrorMessage"] as? String)
                ?? "unknown error"
            return "Couldn't move to Trash: \(msg). ForgedBrew may need Full Disk Access, or the app may be running."
        }
        return nil
    }

    // MARK: - Orphaned packages

    // Asks Homebrew itself which formulae are orphaned (installed only as a
    // dependency, now required by nothing) via `brew autoremove --dry-run`,
    // then enriches each with a version and on-disk keg size so the UI can
    // show what's there and how much removing it reclaims.
    //
    // We parse autoremove's output rather than recomputing from `brew leaves`
    // because Homebrew's resolver correctly excludes build dependencies of
    // source-built formulae and other edge cases that naive leaf math misses.
    func scanOrphanedPackages() async -> OrphanScanResult {
        // `brew autoremove --dry-run` prints a header line followed by one
        // formula token per line, e.g.:
        //   ==> Would autoremove 3 unneeded formulae:
        //   gettext
        //   libidn2
        //   pcre2
        // On a clean system it prints nothing. We tolerate either shape.
        guard let raw = try? await collect(["autoremove", "--dry-run"]) else {
            return .empty
        }

        var tokens: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Skip brew's progress/header chatter ("==> …") and any line that
            // isn't a bare formula token (tokens never contain whitespace).
            if trimmed.hasPrefix("==>") { continue }
            if trimmed.contains(" ") || trimmed.contains("\t") { continue }
            tokens.append(trimmed)
        }

        guard !tokens.isEmpty else { return .empty }

        // Resolve the Homebrew prefix once so we can build Cellar keg paths.
        let prefix = (try? await collect(["--prefix"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "/opt/homebrew"
        let cellarRoot = prefix + "/Cellar"

        // Version lookup in one pass: `brew list --versions <t1> <t2> …`
        // prints "<token> <version> [<version> …]" per line. Map token→first
        // version. Best-effort; missing entries just yield nil.
        var versionByToken: [String: String] = [:]
        if let versionsOut = try? await collect(["list", "--versions"] + tokens) {
            for line in versionsOut.components(separatedBy: "\n") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2 else { continue }
                versionByToken[String(parts[0])] = String(parts[1])
            }
        }

        // Build Cellar paths and size them all in one `du -sk` pass.
        var cellarByToken: [String: String] = [:]
        for token in tokens {
            let path = cellarRoot + "/" + token
            if FileManager.default.fileExists(atPath: path) {
                cellarByToken[token] = path
            }
        }
        let sizes = await sizesForPaths(Array(cellarByToken.values))

        var packages: [OrphanedPackage] = []
        for token in tokens {
            let cellar = cellarByToken[token]
            let bytes = cellar.flatMap { sizes[$0] }.map { Int64($0) }
            packages.append(OrphanedPackage(
                token: token,
                version: versionByToken[token],
                sizeBytes: bytes,
                cellarPath: cellar
            ))
        }

        packages.sort { $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending }
        return OrphanScanResult(packages: packages)
    }

    // Removes ONE orphaned formula via `brew uninstall --formula <token>`.
    // Returns nil on success or a user-facing error string on failure, so the
    // sheet can show exactly what went wrong (e.g. "still has dependents").
    func removeOrphanedPackage(_ package: OrphanedPackage) async -> String? {
        await drainUninstall(self.uninstallFormula(package.token), label: package.token)
    }

    // Removes EVERY orphaned formula in one shot via `brew autoremove` (no
    // --dry-run). Returns nil on success or a user-facing error string. This is
    // the "Remove All" path; afterward the caller should re-scan to refresh the
    // (now hopefully empty) list.
    func removeAllOrphanedPackages() async -> String? {
        await drainUninstall(self.autoremove(), label: "autoremove")
    }

    // MARK: - Disk footprint

    // Measures where Homebrew's disk space goes: the Cellar (installed
    // formulae), the download cache, and the Taps (git repositories). Each is
    // resolved via brew's own path queries and sized with a single `du -sk`
    // pass over all three at once. Components whose path is missing or empty
    // report 0 bytes rather than being dropped, so the breakdown is stable.
    //
    // The "Apps" component is sized from the Caskroom (`<prefix>/Caskroom`),
    // which is what Homebrew actually keeps on disk for each installed cask app.
    // We used to list Apps and Caskroom as two separate rows, but they describe
    // the same thing — and the old "Apps" row (summed from
    // InstalledPackage.sizeBytes) frequently came through as 0. So Apps now
    // reports the measured Caskroom size, and there is no separate Caskroom row.
    // `caskAppsBytes` is retained only as a fallback for the rare case where the
    // Caskroom path can't be resolved or measured.
    func measureDiskFootprint(caskAppsBytes: Int64) async -> DiskFootprint {
        // Resolve the prefix-relative locations. `--repository` gives the brew
        // repo root; taps live under <repo>/Library/Taps. The Caskroom sits at
        // <prefix>/Caskroom and holds the installed cask payloads ("Apps").
        let prefix = (try? await collect(["--prefix"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cellar = (try? await collect(["--cellar"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cache = (try? await collect(["--cache"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = (try? await collect(["--repository"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let caskroom = prefix.map { $0 + "/Caskroom" }
        let taps = repo.map { $0 + "/Library/Taps" }

        // Map each measurable kind to its resolved path (nil/empty paths drop
        // out of the du pass but still appear in the breakdown at 0 bytes).
        // .apps is measured from the Caskroom path (it IS the installed casks).
        let pathByKind: [DiskFootprintComponent.Kind: String?] = [
            .apps: caskroom,
            .cellar: cellar,
            .cache: cache,
            .taps: taps
        ]

        let measurablePaths = pathByKind.values
            .compactMap { $0 }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        let sizes = await sizesForPaths(measurablePaths)

        // Build a component per kind in a stable order. Apps is the Caskroom
        // size; if that can't be measured, fall back to the passed-in total.
        var components: [DiskFootprintComponent] = []
        for kind in DiskFootprintComponent.Kind.allCases {
            let path = pathByKind[kind] ?? nil
            var bytes = path.flatMap { sizes[$0] }.map { Int64($0) } ?? 0
            if kind == .apps && bytes == 0 { bytes = max(0, caskAppsBytes) }
            components.append(DiskFootprintComponent(kind: kind, bytes: bytes, path: path))
        }
        return DiskFootprint(components: components)
    }
}
