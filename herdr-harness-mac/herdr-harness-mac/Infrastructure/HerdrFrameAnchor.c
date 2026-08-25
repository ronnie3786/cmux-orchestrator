#include "HerdrFrameAnchor.h"

__attribute__((noinline))
void herdr_capture_backtrace_anchor(uintptr_t *outFP, uintptr_t *outPC) {
#if defined(__arm64__)
    uintptr_t myFrame = (uintptr_t)__builtin_frame_address(0);
    uintptr_t *frame = (uintptr_t *)myFrame;
    *outFP = frame[0];
    *outPC = frame[1];
#else
    *outFP = 0;
    *outPC = 0;
#endif
}
