#line 2 "../src/sandbox.h"
//#############################################################################
// ----------------------------------------------------------------------------
// C include file for sandbox.
//
//#############################################################################

#ifndef SANDBOX_H
#define SANDBOX_H

#include "bits.h"
#include "output.h"
#include "sprintull.h"

#if defined(_WIN32)
#define strtoull _strtoui64
#endif

const int MODE_COUNT = 1;
const int MODE_PRINT = 2;
const int MODE_SUM   = 3;

#endif

