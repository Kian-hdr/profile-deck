#include "ProcessActivationBridge.h"
#include <ApplicationServices/ApplicationServices.h>

// These public functions are deprecated, but remain present in macOS 26's
// Apple-silicon SDK. Swift does not import pre-10.10 deprecated APIs. Keep the
// compatibility boundary here rather than declaring private/dynamic symbols.
int32_t PDResolveProcess(int32_t pid, PDProcessReference *reference) {
    ProcessSerialNumber serial = {0, 0};
    OSStatus status = GetProcessForPID(pid, &serial);
    if (status == noErr) {
        reference->high = serial.highLongOfPSN;
        reference->low = serial.lowLongOfPSN;
    }
    return status;
}

int32_t PDActivateProcess(PDProcessReference reference, int32_t expectedPID, bool userInitiated) {
    ProcessSerialNumber serial = {reference.high, reference.low};
    pid_t actualPID = 0;
    OSStatus status = GetProcessPID(&serial, &actualPID);
    if (status != noErr) return status;
    if (actualPID != expectedPID) return paramErr;
    OptionBits flags = kSetFrontProcessFrontWindowOnly;
    if (userInitiated) flags |= kSetFrontProcessCausedByUser;
    return SetFrontProcessWithOptions(&serial, flags);
}
