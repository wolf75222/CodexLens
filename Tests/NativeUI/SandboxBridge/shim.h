#include <sandbox.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

// Diagnostic harness only. Use the SDK's named profile, not private SBPL flags.
// The API is deprecated; a failed installation aborts this profiling mode.
static inline int lens_profile_deny_network(void) {
    char *error = NULL;
    int result = sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, &error);
    sandbox_free_error(error);
    return result;
}

static inline int lens_profile_network_is_denied(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return errno == EPERM || errno == EACCES;
    // Invalid loopback port: no remote host, request or application data.
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    int result = connect(fd, (const struct sockaddr *)&address, sizeof(address));
    int error = errno;
    close(fd);
    return result < 0 && (error == EPERM || error == EACCES);
}
