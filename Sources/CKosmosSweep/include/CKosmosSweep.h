// The api-sweep probe's table of private window calls and the code that performs one on a
// window this process does not own (kosmos-probe/ApiSweep.swift, docs/geometry.md).
//
// Every signature here was taken from a published header dump or a reverse engineered
// project, named in `source`, and marked known, inferred or unknown. Unknown signatures are
// listed, never called. Only entries with kind KSWEEP_CALL are performed; KSWEEP_LIST and
// KSWEEP_EXCLUDE are metadata for the dry run.
#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

// Returned by kosmos_sweep_perform for an entry it does not call.
#define KSWEEP_NOT_CALLED INT64_C(0x7fffffff)

typedef enum {
    KSWEEP_KNOWN = 0,    // a header or reverse engineered project gives the full signature
    KSWEEP_INFERRED = 1, // the signature is deduced from a sibling call or a register dump
    KSWEEP_UNKNOWN = 2,  // no signature found; listed, never called
} KSweepSignature;

typedef enum {
    KSWEEP_CALL = 0,     // performed in the live sweep
    KSWEEP_LIST = 1,     // in scope, listed, not called (unknown signature)
    KSWEEP_EXCLUDE = 2,  // too risky to call; listed with a reason in `note`
} KSweepKind;

typedef struct {
    const char *name;       // the export, e.g. "SLSSetWindowAlpha"
    const char *category;   // read, move, size, bounds, transform, alpha, level, order, space,
                            // shape, resolution, updates
    const char *signature;  // the C signature the probe uses, for the list
    int status;             // KSweepSignature
    const char *source;     // where the signature came from
    const char *args;       // the argument values a call uses, in words
    int risk;               // 0 lowest; the sweep runs in this order, updates and levels and
                            // shapes last
    int kind;               // KSweepKind
    const char *note;       // an exclusion reason or an extra note, or ""
} KSweepEntry;

// The window's frame, alpha, level, ordering and on-screen transform, as one read gives them.
typedef struct {
    CGRect bounds;
    float alpha;
    int level;
    int orderedIn;
    CGAffineTransform transform;
    int ok;                 // 1 when the window query returned a row
} KSweepState;

int kosmos_sweep_count(void);
const KSweepEntry *kosmos_sweep_entry(int index);

// Reads the window back through SLSWindowQueryWindows and SLSGetWindowTransform, on this
// process's own connection. A read of another app's window needs no rights.
KSweepState kosmos_sweep_read(uint32_t window);

// Performs entry `index` on `window` from this process's own connection, creating and
// committing a transaction where the call needs one. Returns the CGError, or
// KSWEEP_NOT_CALLED for an entry the probe does not call. The caller isolates this in a
// short-lived process, so a client-side crash or hang does not stop the sweep.
int64_t kosmos_sweep_perform(int index, uint32_t window);

// Restores the window to `rest` from its owner's connection, which holds rights on it:
// frame, alpha, level, sublevel, transform, locked bounds and ordering. The window's owner
// calls this between sweep calls.
void kosmos_sweep_reset(uint32_t window, CGRect rest);

#include "Peek.h"
