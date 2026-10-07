#include "IndependentAppLaunch.h"
#include <spawn.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
extern char **environ;

int ctm_launch_independent(const char *path, char *const arguments[], pid_t *pid) {
    // macOS otherwise attributes an app started from a terminal/IDE to its
    // launcher. Its menu-bar visibility can then follow the launcher's switch.
    // Resolve the same process-responsibility attribute used by LLVM's macOS
    // launcher dynamically, without changing any OS permissions/preferences.
    int (*disclaim)(posix_spawnattr_t *, bool) =
        dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (!disclaim) return ENOTSUP;
    posix_spawnattr_t attributes;
    int result = posix_spawnattr_init(&attributes);
    if (result) return result;
    result = disclaim(&attributes, true);
    if (!result) result = posix_spawn(pid, path, NULL, &attributes, arguments, environ);
    posix_spawnattr_destroy(&attributes);
    return result;
}
