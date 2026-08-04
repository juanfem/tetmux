#ifndef TETMUX_CUTIL_SHIM_H
#define TETMUX_CUTIL_SHIM_H

/* glibc puts forkpty/openpty here; the Glibc module does not surface them. */
#include <pty.h>

#endif /* TETMUX_CUTIL_SHIM_H */
