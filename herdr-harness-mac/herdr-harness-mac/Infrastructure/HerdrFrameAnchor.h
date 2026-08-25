#ifndef HERDR_FRAME_ANCHOR_H
#define HERDR_FRAME_ANCHOR_H

#include <stdint.h>

void herdr_capture_backtrace_anchor(uintptr_t *outFP, uintptr_t *outPC);

#endif
