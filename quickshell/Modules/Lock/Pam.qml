pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Common

Scope {
    id: root

    property bool lockSecured: false
    property bool unlockInProgress: false

    readonly property alias passwd: passwd
    readonly property alias fprint: fprint
    readonly property alias u2f: u2f
    property string lockMessage
    property string state
    property string fprintState
    property string u2fState
    property bool u2fPending: false
    property string u2fPendingMode
    property string buffer

    property var attemptInfoMessages: []
    property bool lockoutAnnouncedThisAttempt: false

    signal flashMsg
    signal unlockRequested

    function resetAuthFlows(): void {
        passwd.abort();
        fprint.abort();
        u2f.abort();
        errorRetry.running = false;
        fprintArm.running = false;
        u2fErrorRetry.running = false;
        u2fPendingTimeout.running = false;
        passwdActiveTimeout.running = false;
        unlockRequestTimeout.running = false;
        root.u2fPending = false;
        root.u2fPendingMode = "";
        root.u2fState = "";
        root.unlockInProgress = false;
    }

    function recoverFromAuthStall(newState: string): void {
        resetAuthFlows();
        root.state = newState;
        flashMsg();
        stateReset.restart();
        fprint.checkAvail();
        u2f.checkAvail();
    }

    function completeUnlock(): void {
        if (!root.unlockInProgress) {
            root.unlockInProgress = true;
            passwd.abort();
            fprint.abort();
            u2f.abort();
            errorRetry.running = false;
            fprintArm.running = false;
            u2fErrorRetry.running = false;
            u2fPendingTimeout.running = false;
            root.u2fPending = false;
            root.u2fPendingMode = "";
            root.u2fState = "";
            unlockRequestTimeout.restart();
            unlockRequested();
        }
    }

    function proceedAfterPrimaryAuth(): void {
        if (!root.u2fSuppressedByPrimaryPam && SettingsData.enableU2f && SettingsData.u2fMode === "and" && u2f.available) {
            u2f.startForSecondFactor();
        } else {
            completeUnlock();
        }
    }

    function cancelU2fPending(): void {
        if (!root.u2fPending)
            return;
        u2f.abort();
        u2fErrorRetry.running = false;
        u2fPendingTimeout.running = false;
        root.u2fPending = false;
        root.u2fPendingMode = "";
        root.u2fState = "";
        fprint.checkAvail();
    }

    readonly property bool customPamActive: SettingsData.lockPamPath !== "" && customPamWatcher.loaded
    readonly property bool fprintSuppressedByPrimaryPam: SettingsData.lockPamExternallyManaged || (customPamActive && SettingsData.lockPamInlineFprint)
    readonly property bool u2fSuppressedByPrimaryPam: SettingsData.lockPamExternallyManaged || (customPamActive && SettingsData.lockPamInlineU2f)
    readonly property bool customU2fPamActive: SettingsData.lockU2fPamPath !== "" && customU2fPamWatcher.loaded

    FileView {
        id: customPamWatcher

        path: SettingsData.lockPamPath !== "" ? SettingsData.lockPamPath : ""
        printErrors: false
    }

    FileView {
        id: dankshellConfigWatcher

        path: "/etc/pam.d/dankshell"
        printErrors: false
    }

    FileView {
        id: u2fConfigWatcher

        path: "/etc/pam.d/dankshell-u2f"
        watchChanges: true
        printErrors: false
    }

    FileView {
        id: customU2fPamWatcher

        path: SettingsData.lockU2fPamPath !== "" ? SettingsData.lockU2fPamPath : ""
        printErrors: false
    }

    // Fallback stack written by `dms auth resolve-lock` when no managed
    // /etc/pam.d/dankshell exists. See #2789.
    readonly property string userPamDir: Paths.strip(Paths.state) + "/pam"

    FileView {
        id: userPamWatcher

        path: root.userPamDir + "/dankshell"
        printErrors: false
    }

    Process {
        id: resolveUserPam

        command: ["dms", "auth", "resolve-lock", "--quiet"]
        running: false
        onExited: exitCode => {
            if (exitCode === 0)
                userPamWatcher.reload();
        }
    }

    function ensureUserPamConfig(): void {
        if (SettingsData.lockPamExternallyManaged || resolveUserPam.running)
            return;
        resolveUserPam.running = true;
    }

    Component.onCompleted: ensureUserPamConfig()

    PamContext {
        id: passwd

        config: {
            if (root.customPamActive)
                return SettingsData.lockPamPath.slice(SettingsData.lockPamPath.lastIndexOf("/") + 1);
            if (SettingsData.lockPamExternallyManaged)
                return "login";
            if (dankshellConfigWatcher.loaded)
                return "dankshell";
            if (userPamWatcher.loaded)
                return "dankshell";
            return "login";
        }
        configDirectory: {
            if (root.customPamActive) {
                const idx = SettingsData.lockPamPath.lastIndexOf("/");
                return idx > 0 ? SettingsData.lockPamPath.slice(0, idx) : "/";
            }
            if (SettingsData.lockPamExternallyManaged)
                return "/etc/pam.d";
            if (dankshellConfigWatcher.loaded)
                return "/etc/pam.d";
            if (userPamWatcher.loaded)
                return root.userPamDir;
            return Quickshell.shellDir + "/assets/pam";
        }

        onMessageChanged: {
            // collected by position, not text, so it works in any locale
            if (message.length > 0 && !responseRequired)
                root.attemptInfoMessages = root.attemptInfoMessages.concat([message]);
        }

        onResponseRequiredChanged: {
            if (!responseRequired)
                return;

            const notice = root.attemptInfoMessages.filter(m => m !== message);
            if (notice.length > 0) {
                root.lockMessage = notice.join("\n");
                root.lockoutAnnouncedThisAttempt = true;
            }
            root.attemptInfoMessages = [];

            respond(root.buffer);
        }

        onCompleted: res => {
            // requisite preauth can lock without ever prompting; surface it here too
            if (!root.lockoutAnnouncedThisAttempt) {
                if (root.attemptInfoMessages.length > 0) {
                    root.lockMessage = root.attemptInfoMessages.join("\n");
                    root.lockoutAnnouncedThisAttempt = true;
                } else {
                    root.lockMessage = "";
                }
                root.attemptInfoMessages = [];
            }

            if (res === PamResult.Success) {
                if (!root.unlockInProgress) {
                    fprint.abort();
                    root.proceedAfterPrimaryAuth();
                }
                return;
            }

            unlockRequestTimeout.running = false;
            root.unlockInProgress = false;
            root.u2fPending = false;
            root.u2fPendingMode = "";
            root.u2fState = "";
            u2fPendingTimeout.running = false;
            u2f.abort();

            if (res === PamResult.Error)
                root.state = "error";
            else if (res === PamResult.MaxTries)
                root.state = "max";
            else if (res === PamResult.Failed)
                root.state = "fail";

            root.flashMsg();
            stateReset.restart();
        }
    }

    Connections {
        target: passwd

        function onActiveChanged() {
            if (passwd.active) {
                root.attemptInfoMessages = [];
                root.lockoutAnnouncedThisAttempt = false;
                passwdActiveTimeout.restart();
            } else {
                passwdActiveTimeout.running = false;
            }
        }
    }

    PamContext {
        id: fprint

        property bool available: SettingsData.lockFingerprintReady
        property int tries
        property int errorTries
        property bool retrying: false
        // set once consecutive hard errors show fprintd/libfprint is wedged
        // rather than transiently unhappy. Stops the re-fork loop.
        property bool degraded: false

        // Consecutive PamResult.Error results tolerated before giving up.
        // Every attempt fork()s a fresh PAM child out of the multithreaded
        // shell process, and a wedged fprintd only recovers once we stop
        // talking to it long enough for its idle timeout to fire.
        readonly property int maxErrorTries: 4

        // The ONLY path that may call start(). Never call start() directly
        // from onCompleted: the C++ PamContext is still unwinding the old
        // PamConversation (deleteLater) at that point, so a synchronous
        // start() forks a new PAM child while the old one is still alive.
        function armStart(): void {
            if (!available || !SettingsData.enableFprint || !root.lockSecured || root.fprintSuppressedByPrimaryPam || degraded || root.unlockInProgress) {
                retrying = false;
                return;
            }
            if (active || fprintArm.running)
                return;
            fprintArm.restart();
        }

        function checkAvail(): void {
            if (!available || !SettingsData.enableFprint || !root.lockSecured || root.fprintSuppressedByPrimaryPam) {
                retrying = false;
                errorRetry.running = false;
                fprintArm.running = false;
                abort();
                return;
            }
            if (active || fprintArm.running)
                return;

            tries = 0;
            errorTries = 0;
            retrying = false;
            degraded = false;
            armStart();
        }

        // User-driven "try the reader again" after we gave up. Keeps
        // fingerprint a first-class unlock method instead of a one-shot.
        function rearm(): void {
            if (!available || !SettingsData.enableFprint || !root.lockSecured || root.fprintSuppressedByPrimaryPam)
                return;
            errorRetry.running = false;
            fprintArm.running = false;
            retrying = false;
            degraded = false;
            errorTries = 0;
            tries = 0;
            if (root.fprintState === "unavailable" || root.fprintState === "max")
                root.fprintState = "";
            armStart();
        }

        config: "fprint"
        configDirectory: Quickshell.shellDir + "/assets/pam"

        onCompleted: res => {
            if (!available)
                return;

            switch (res) {
            case PamResult.Success:
                retrying = false;
                errorTries = 0;
                errorRetry.running = false;
                fprintArm.running = false;
                if (!root.unlockInProgress) {
                    passwd.abort();
                    root.proceedAfterPrimaryAuth();
                }
                return;
            case PamResult.Error:
                errorTries++;
                if (errorTries < maxErrorTries) {
                    retrying = true;
                    errorRetry.restart();
                    return;
                }
                // fprintd is not coming back on its own while we keep
                // hammering it. Stand down, surface it, let the user fall
                // back to the password field (and let fprintd idle-exit,
                // which is what actually clears the libfprint wedge).
                retrying = false;
                degraded = true;
                errorRetry.running = false;
                fprintArm.running = false;
                root.fprintState = "unavailable";
                break;
            case PamResult.MaxTries:
                // The reader physically read fingers, so it is alive:
                // this is not the wedged case, clear the error budget.
                retrying = false;
                errorTries = 0;
                tries++;
                if (tries < SettingsData.maxFprintTries) {
                    root.fprintState = "fail";
                    armStart();
                } else {
                    root.fprintState = "max";
                    abort();
                }
                break;
            default:
                return;
            }

            root.flashMsg();
            fprintStateReset.start();
        }
    }

    PamContext {
        id: u2f

        property bool available: SettingsData.lockU2fReady

        function checkAvail(): void {
            if (!available || !SettingsData.enableU2f || !root.lockSecured || root.u2fSuppressedByPrimaryPam) {
                abort();
                return;
            }

            if (SettingsData.u2fMode === "or")
                abort();
        }

        function startForSecondFactor(): void {
            if (!available || !SettingsData.enableU2f || root.u2fSuppressedByPrimaryPam) {
                root.completeUnlock();
                return;
            }
            abort();
            root.u2fPending = true;
            root.u2fPendingMode = "and";
            root.u2fState = "";
            u2fPendingTimeout.restart();
            start();
        }

        function startForAlternativeAuth(): void {
            if (!available || !SettingsData.enableU2f || root.u2fSuppressedByPrimaryPam || SettingsData.u2fMode !== "or" || root.unlockInProgress || passwd.active || active)
                return;
            abort();
            root.u2fPending = true;
            root.u2fPendingMode = "or";
            root.u2fState = "";
            u2fPendingTimeout.restart();
            start();
        }

        config: {
            if (root.customU2fPamActive)
                return SettingsData.lockU2fPamPath.slice(SettingsData.lockU2fPamPath.lastIndexOf("/") + 1);
            return u2fConfigWatcher.loaded ? "dankshell-u2f" : "u2f";
        }
        configDirectory: {
            if (root.customU2fPamActive) {
                const idx = SettingsData.lockU2fPamPath.lastIndexOf("/");
                return idx > 0 ? SettingsData.lockU2fPamPath.slice(0, idx) : "/";
            }
            return u2fConfigWatcher.loaded ? "/etc/pam.d" : Quickshell.shellDir + "/assets/pam";
        }

        onMessageChanged: {
            if (message.toLowerCase().includes("touch"))
                root.u2fState = "waiting";
        }

        onCompleted: res => {
            if (!available || root.unlockInProgress)
                return;

            if (res === PamResult.Success) {
                root.completeUnlock();
                return;
            }

            if (res === PamResult.Error || res === PamResult.MaxTries || res === PamResult.Failed) {
                abort();

                if (root.u2fPending) {
                    if (root.u2fPendingMode === "or") {
                        root.u2fPending = false;
                        root.u2fPendingMode = "";
                        root.u2fState = root.u2fState === "waiting" ? "" : "insert";
                        u2fPendingTimeout.running = false;
                        fprint.checkAvail();
                        return;
                    }

                    if (root.u2fState === "waiting") {
                        // AND mode: device was found but auth failed → back to password
                        root.u2fPending = false;
                        root.u2fPendingMode = "";
                        root.u2fState = "";
                        fprint.checkAvail();
                    } else {
                        // AND mode: no device found → keep pending, show "Insert...", retry
                        root.u2fState = "insert";
                        u2fErrorRetry.restart();
                    }
                } else {
                    root.u2fState = "insert";
                }
            }
        }
    }

    Timer {
        id: errorRetry

        // 4s, 8s, 16s ... capped. Each retry costs a fork() of the shell
        // plus a full fprintd verify timeout, so retrying cheaply is not free.
        interval: Math.min(4000 * Math.pow(2, Math.max(0, fprint.errorTries - 1)), 60000)
        onTriggered: fprint.armStart()
    }

    // Single funnel for fprint.start(). The delay guarantees we are outside
    // the completed() emission and past the deferred delete of the previous
    // PamConversation, so we never have two PAM children in flight.
    Timer {
        id: fprintArm

        interval: 400
        onTriggered: {
            if (!fprint.available || !SettingsData.enableFprint || !root.lockSecured || root.fprintSuppressedByPrimaryPam || fprint.degraded || root.unlockInProgress || fprint.active) {
                fprint.retrying = false;
                return;
            }
            fprint.retrying = false;
            fprint.start();
        }
    }

    Timer {
        id: u2fErrorRetry

        interval: 800
        onTriggered: u2f.start()
    }

    Timer {
        id: u2fPendingTimeout

        interval: 30000
        onTriggered: root.cancelU2fPending()
    }

    Timer {
        id: passwdActiveTimeout

        interval: 15000
        onTriggered: {
            if (passwd.active)
                root.recoverFromAuthStall("error");
        }
    }

    Timer {
        id: unlockRequestTimeout

        interval: 8000
        onTriggered: {
            if (root.unlockInProgress)
                root.recoverFromAuthStall("error");
        }
    }

    Timer {
        id: stateReset

        interval: 4000
        onTriggered: {
            if (root.state !== "max")
                root.state = "";
        }
    }

    Timer {
        id: fprintStateReset

        interval: 4000
        onTriggered: root.fprintState = ""
    }

    onLockSecuredChanged: {
        if (!lockSecured) {
            root.resetAuthFlows();
            return;
        }
        root.state = "";
        root.fprintState = "";
        root.u2fState = "";
        root.u2fPending = false;
        root.u2fPendingMode = "";
        root.lockMessage = "";
        root.attemptInfoMessages = [];
        root.lockoutAnnouncedThisAttempt = false;
        root.resetAuthFlows();
        if (!SettingsData.lockPamExternallyManaged && !dankshellConfigWatcher.loaded && !userPamWatcher.loaded)
            ensureUserPamConfig();
        // FileView cannot watch a path that does not exist yet; re-read so a
        // dedicated service created after startup is used on the next lock.
        u2fConfigWatcher.reload();
        fprint.checkAvail();
        u2f.checkAvail();
    }

    Connections {
        target: SettingsData

        function onEnableFprintChanged(): void {
            fprint.checkAvail();
        }

        function onLockFingerprintReadyChanged(): void {
            fprint.checkAvail();
        }

        function onEnableU2fChanged(): void {
            u2f.checkAvail();
        }

        function onLockU2fReadyChanged(): void {
            u2f.checkAvail();
        }

        function onLockPamPathChanged(): void {
            fprint.checkAvail();
            u2f.checkAvail();
        }

        function onLockPamInlineFprintChanged(): void {
            fprint.checkAvail();
        }

        function onLockPamInlineU2fChanged(): void {
            u2f.checkAvail();
        }

        function onLockPamExternallyManagedChanged(): void {
            root.resetAuthFlows();
            if (!SettingsData.lockPamExternallyManaged)
                root.ensureUserPamConfig();
            fprint.checkAvail();
            u2f.checkAvail();
        }

        function onLockU2fPamPathChanged(): void {
            u2f.abort();
            u2f.checkAvail();
        }

        function onU2fModeChanged(): void {
            if (root.lockSecured) {
                u2f.abort();
                u2fErrorRetry.running = false;
                u2fPendingTimeout.running = false;
                unlockRequestTimeout.running = false;
                root.u2fPending = false;
                root.u2fPendingMode = "";
                root.u2fState = "";
                u2f.checkAvail();
            }
        }
    }
}
