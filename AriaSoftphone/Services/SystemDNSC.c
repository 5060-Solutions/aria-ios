#include "SystemDNSC.h"
#include <resolv.h>
#include <netdb.h>
#include <string.h>
#include <stdlib.h>

int aria_system_dns_server(int index, char *out, unsigned long len) {
    struct __res_9_state *state = calloc(1, sizeof(*state));
    if (!state) return 0;
    int ok = 0;
    if (res_9_ninit(state) == 0) {
        union res_sockaddr_union found[8];
        memset(found, 0, sizeof(found));
        int count = res_9_getservers(state, found, 8);
        if (index >= 0 && index < count && index < 8) {
            struct sockaddr *sa = (struct sockaddr *)&found[index];
            socklen_t sl = sa->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6)
                         : sa->sa_family == AF_INET ? sizeof(struct sockaddr_in) : 0;
            if (sl != 0 && getnameinfo(sa, sl, out, (socklen_t)len, NULL, 0, NI_NUMERICHOST) == 0) ok = 1;
        }
        res_9_ndestroy(state);
    }
    free(state);
    return ok;
}
