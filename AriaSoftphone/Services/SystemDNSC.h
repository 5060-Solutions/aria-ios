#ifndef SystemDNSC_h
#define SystemDNSC_h

/// Writes the numeric address of the `index`th DNS server libresolv reports
/// ("fe80::1%en0" keeps its scope) into `out` (`len` bytes). Returns 1, or 0
/// when there is no such server.
int aria_system_dns_server(int index, char *out, unsigned long len);

#endif
