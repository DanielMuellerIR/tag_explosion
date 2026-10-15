// Kleine App-Hülle für den Paketversuch, ohne Swift-/TagLib-Abhängigkeit.
// Der Java-Pfad wird aus dem tatsächlich gestarteten Bundle abgeleitet.
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    char executable[PATH_MAX], resolved[PATH_MAX], java[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) return 1;
    char *end = strrchr(resolved, '/');
    if (!end) return 1;
    *end = 0;
    int length = snprintf(java, sizeof(java),
        "%s/../Resources/XRechnungValidator/runtime/Contents/Home/bin/java", resolved);
    if (length < 0 || (size_t)length >= sizeof(java)) return 1;
    argv[0] = java;
    execv(java, argv);
    perror("private Java");
    return 1;
}
